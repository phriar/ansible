# Ansible Infrastructure

This repository builds the **autoserver** — an Ubuntu VM that acts as both an Ansible control node and an nginx OVA/ISO file server. It's designed to be built on an internet-connected network, staged with OVAs/ISOs and Galaxy collections, exported as an OVA, then deployed into an air-gapped network where it drives all further VM deployment and configuration offline.

```
Internet-connected              Air-gapped network
──────────────────              ──────────────────
1. Build Ubuntu VM              5. Deploy autoserver OVA to ESXi
2. Run bootstrap.sh             6. Boot — everything works offline
3. Stage OVAs and ISOs          7. Run playbooks to deploy all VMs
4. Export as OVA  ─────────────────────────────────────────▶
```

---

## Quick start

```bash
# 1. Install required Galaxy collections
ansible-galaxy collection install -r requirements.yml

cd autoserver

# 2. Encrypt the vault file before committing
ansible-vault encrypt inventory/group_vars/all/vault.yml

# 3. Dry-run against standalone ESXi
ansible-playbook deploy-esxi.yml --check --diff --ask-vault-pass

# 4. Deploy for real
ansible-playbook deploy-esxi.yml --ask-vault-pass
```

---

## Directory structure

```
.
├── ansible.cfg                          # Global Ansible settings
├── requirements.yml                     # Galaxy collections required before running
├── .gitignore                           # Excludes vault files, .retry files, keys, and certs
│
├── autoserver/                          # The project — everything runs from here
│   ├── bootstrap.sh                     # Run once, as root, on the internet-connected build VM
│   │
│   ├── deploy-esxi.yml                  # Deploy VMs from local OVA repo to standalone ESXi
│   ├── deploy-vcenter.yml               # Deploy VMs from local OVA repo to vCenter
│   ├── deploy-vm-template.yml           # Clone a VM from a vCenter template (non-OVA approach)
│   ├── deploy-from-ova.yml              # Deploy a single VM from an OVA
│   ├── create-windows-vm.yml            # Build a Windows VM from scratch
│   ├── convert-to-template.yml          # Convert a built VM into a reusable vCenter template
│   ├── configure-rhel.yml               # Post-deploy hardening for RHEL/Rocky VMs
│   ├── configure-windows.yml            # Post-deploy config for Windows Server VMs
│   │
│   ├── inventory/
│   │   ├── hosts.yml                    # esxi / rhel / windows / vendor host groups
│   │   └── group_vars/all/
│   │       ├── vars.yml                 # ESXi/vCenter connection info, nginx repo URL, NTP
│   │       ├── vm_catalog.yml           # Single source of truth for every VM to deploy
│   │       └── vault.yml                # Encrypted secrets — MUST be encrypted with ansible-vault
│   │
│   ├── roles/
│   │   ├── rename/                      # Sets hostname (Windows + Linux)
│   │   ├── network/                     # Applies static IP/gateway (Windows + Linux)
│   │   └── domain_join/                 # Joins a VM to the poseidon.local AD domain
│   │
│   ├── vars/                            # Extra-vars files for the create/convert/deploy playbooks
│   ├── scripts/                         # Helper scripts
│   └── templates/                       # Jinja2 templates
│
└── docs/
    ├── autoserver-design.md             # Full design doc, architecture, pre-export checklist
    ├── windows-domain-join.md           # Domain join runbook for poseidon.local
    ├── deploy-vm-template.md            # Reference for the vCenter template-clone approach
    ├── ubuntu-ansible-setup.md          # Setting up Ubuntu as an Ansible control node
    └── user-guide.md                    # Day-to-day workflow
```

---

## VM catalog

`autoserver/inventory/group_vars/all/vm_catalog.yml` is the single source of truth for every VM — name, group, OVA path, datastore, port group, memory, CPU, disk, IP, OVF properties. The deploy playbooks loop over this list.

| Name | Group |
|---|---|
| `rocky-01` | rhel |
| `win-server-01` | windows |
| `infoblox-01` | vendor |
| `nsx-manager-01` | vendor |

```bash
# Deploy everything
ansible-playbook deploy-esxi.yml --ask-vault-pass

# Deploy one group
ansible-playbook deploy-esxi.yml --tags rhel --ask-vault-pass

# Deploy a single VM by name
ansible-playbook deploy-esxi.yml -e vm_filter=infoblox-01 --ask-vault-pass
```

---

## Variable precedence (low → high)

1. `autoserver/inventory/group_vars/all/vars.yml` — ESXi/vCenter connection, nginx repo URL, NTP
2. `autoserver/inventory/group_vars/all/vm_catalog.yml` — per-VM specs
3. `autoserver/inventory/group_vars/all/vault.yml` — encrypted secrets
4. CLI `-e` extra vars

---

## Vault (secrets)

All secrets live in `autoserver/inventory/group_vars/all/vault.yml`, prefixed with `vault_`, and are gitignored until encrypted.

```bash
# Encrypt (do this before first commit)
ansible-vault encrypt autoserver/inventory/group_vars/all/vault.yml

# Edit in place
ansible-vault edit autoserver/inventory/group_vars/all/vault.yml

# Run a playbook with vault (prompts for password)
ansible-playbook deploy-esxi.yml --ask-vault-pass
```

---

## Roles

| Role | Purpose |
|---|---|
| `rename` | Sets the hostname on a deployed VM (Windows or Linux) |
| `network` | Applies static IP/gateway from `vm_catalog.yml` (Windows or Linux) |
| `domain_join` | Joins a VM to the `poseidon.local` AD domain — see `docs/windows-domain-join.md` |

---

## Connectivity checks

```bash
ansible rhel    -m ansible.builtin.ping
ansible windows -m ansible.windows.win_ping --ask-vault-pass
```

---

## Requirements

- Ansible >= 2.14, Python >= 3.9 on the control node
- SSH key at `~/.ssh/id_ed25519` (or `~/.ssh/ansible_id_rsa` on the autoserver)
- Remote user `ansible` with passwordless sudo on Linux targets; WinRM with NTLM on Windows
- Collections in `requirements.yml`: `community.vmware`, `ansible.windows`, `community.windows`, `ansible.posix`, `community.general`, `microsoft.ad` — all cached offline by `bootstrap.sh`

See `docs/autoserver-design.md` for the full design doc and pre-export checklist.
