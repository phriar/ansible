# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install Galaxy dependencies (required before first run)
ansible-galaxy collection install -r requirements.yml

# Run from autoserver/ directory for all autoserver playbooks
cd autoserver

# Dry-run against staging
ansible-playbook deploy-esxi.yml --check --diff --ask-vault-pass

# Deploy all VMs to standalone ESXi
ansible-playbook deploy-esxi.yml --ask-vault-pass

# Deploy one group (rhel | windows | vendor)
ansible-playbook deploy-esxi.yml --tags rhel --ask-vault-pass

# Deploy a single VM by name
ansible-playbook deploy-esxi.yml -e vm_filter=infoblox-01 --ask-vault-pass

# Deploy to vCenter (once vCenter is up)
ansible-playbook deploy-vcenter.yml --ask-vault-pass

# Configure deployed VMs post-deploy
ansible-playbook configure-rhel-base.yml -l rocky-01 --ask-vault-pass
ansible-playbook configure-windows-base.yml -l win-server-01 --ask-vault-pass

# Clone a VM from a vCenter template (alternative to OVA deploy)
ansible-playbook deploy-vm-template.yml --ask-vault-pass

# Vault operations
ansible-vault encrypt inventory/group_vars/all/vault.yml
ansible-vault edit inventory/group_vars/all/vault.yml

# Test connectivity
ansible rhel    -m ansible.builtin.ping
ansible windows -m ansible.windows.win_ping --ask-vault-pass

# Bootstrap the autoserver (run once, on the internet-connected VM, as root)
sudo bash autoserver/bootstrap.sh
```

## Architecture

The repo is organised around one project: an **autoserver** — an Ubuntu VM that runs as both an Ansible control node and an nginx OVA/ISO file server, designed to be exported as an OVA and deployed into an air-gapped network.

```
Internet-connected              Air-gapped network
──────────────────              ──────────────────
1. Build Ubuntu VM              5. Deploy autoserver OVA to ESXi
2. Run bootstrap.sh             6. Boot — everything works offline
3. Stage OVAs and ISOs          7. Run playbooks to deploy all VMs
4. Export as OVA  ─────────────────────────────────────────▶
```

**Entry points (all in `autoserver/`):**

| Playbook | What it does |
|---|---|
| `deploy-esxi.yml` | Deploy VMs from local OVA repo to standalone ESXi |
| `deploy-vcenter.yml` | Deploy VMs from local OVA repo to vCenter |
| `deploy-vm-template.yml` | Clone a VM from a vCenter template (non-OVA approach) |
| `configure-rhel-base.yml` | Post-deploy hardening for RHEL/Rocky VMs |
| `configure-windows-base.yml` | Post-deploy config for Windows Server VMs |

**VM Catalog (`autoserver/inventory/group_vars/all/vm_catalog.yml`):** Single source of truth for every VM — name, group, OVA path, datastore, port group, memory, CPU, disk, IP, OVF properties. The deploy playbooks loop over this list. Deploy by group with `--tags rhel/windows/vendor` or a single VM with `-e vm_filter=<name>`.

**Variable precedence (low → high):**
1. `autoserver/inventory/group_vars/all/vars.yml` — ESXi/vCenter connection, nginx repo URL, NTP
2. `autoserver/inventory/group_vars/all/vm_catalog.yml` — per-VM specs
3. `autoserver/inventory/group_vars/all/vault.yml` — encrypted secrets (gitignored until encrypted)
4. CLI `-e` extra vars

**Secrets** live in `vault.yml` with `vault_` prefixes. The file is gitignored when unencrypted — encrypt before committing.

**nginx file server:** `bootstrap.sh` configures nginx to serve `/opt/repo` at `http://autoserver/`. ESXi pulls OVAs directly from `http://autoserver/ova/<path>` — no file copy to the datastore needed. OVA paths in `vm_catalog.yml` are relative to `/opt/repo/ova/`.

**Two-phase deployment:**
- Phase 1 (ESXi-only): `deploy-esxi.yml` connects directly to ESXi via pyVmomi
- Phase 2 (vCenter): `deploy-vcenter.yml` connects to vCenter; can specify cluster, folder, resource pool

**Collections required:** `community.vmware`, `ansible.windows`, `community.windows`, `ansible.posix`, `community.general`, `microsoft.ad` — all in `requirements.yml`, all cached offline by `bootstrap.sh`.

## Docs

| File | Contents |
|---|---|
| `docs/autoserver-design.md` | Full design doc, architecture, pre-export checklist, quick reference |
| `docs/windows-domain-join.md` | Domain join runbook for `poseidon.local` |
| `docs/deploy-vm-template.md` | Reference for the vCenter template-clone approach |
| `docs/ubuntu-ansible-setup.md` | Setting up Ubuntu as an Ansible control node |

## Requirements

- Ansible >= 2.14, Python >= 3.9 on control node
- SSH key at `~/.ssh/id_ed25519` (or `~/.ssh/ansible_id_rsa` on the autoserver)
- Remote user is `ansible` with passwordless sudo on Linux targets; WinRM with NTLM on Windows
