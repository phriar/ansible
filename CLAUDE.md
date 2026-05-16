# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install Galaxy dependencies (required before first run)
ansible-galaxy install -r requirements.yml
ansible-galaxy collection install -r requirements.yml

# Dry-run against staging
ansible-playbook -i inventories/staging playbooks/site.yml --check --diff

# Run against production
ansible-playbook -i inventories/production playbooks/site.yml

# Target a single host or tag
ansible-playbook playbooks/site.yml --limit web01.example.com
ansible-playbook playbooks/site.yml --tags packages

# Deploy a VM from vCenter template
ansible-playbook playbooks/deploy_vm.yml -e vm_name=web01 -e vm_ip=10.0.1.60

# Vault operations
ansible-vault encrypt group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml
ansible-playbook playbooks/site.yml --ask-vault-pass
ansible-playbook playbooks/site.yml --vault-password-file ~/.vault_pass

# Initialize a new role scaffold
ansible-galaxy role init roles/<role_name>
```

## Architecture

**Entry points** are playbooks under `playbooks/`. `site.yml` is the master that imports `common.yml`, `webservers.yml`, and `databases.yml` in order. `deploy_vm.yml` is a standalone playbook that runs against `localhost` to provision a VM from a vCenter template via the `community.vmware` collection.

**Variable precedence** (low → high):
1. `roles/<role>/defaults/main.yml` — safe overridable defaults
2. `group_vars/all/vars.yml` — global non-sensitive defaults
3. `inventories/<env>/group_vars/all.yml` — environment-specific overrides (env name, NTP, DNS, timezone)
4. `roles/<role>/vars/main.yml` — high-priority role vars, not meant to be overridden
5. CLI `-e` extra vars — highest priority

**Secrets** live exclusively in `group_vars/all/vault.yml` (encrypted with `ansible-vault`). Convention: vault variables are prefixed `vault_` and re-exposed via plain names in `group_vars/all/vars.yml`. `vault.yml` must be encrypted before committing — it is gitignored when unencrypted by the pattern in `.gitignore`.

**Roles:**
- `common` — applied to every host; installs packages, sets timezone/NTP, applies sysctl, creates the ops user. The `webserver` role declares a dependency on it via `meta/main.yml`.
- `webserver` — installs nginx, renders `nginx.conf.j2` (validated with `nginx -t` before deploy), then loops over `webserver_vhosts` to create and symlink per-vhost configs.

**Inventories** are fully separated by environment under `inventories/staging/` and `inventories/production/`. The default inventory in `ansible.cfg` points to production — always pass `-i inventories/staging` explicitly for staging runs. Host groups used: `[webservers]`, `[databases]`, `[cache]`, and the composite `[app:children]`.

**Galaxy collections** required: `ansible.posix`, `community.general`, `community.mysql`, `community.vmware` (versions pinned in `requirements.yml`).

## Requirements

- Ansible >= 2.14, Python >= 3.9 on control node
- SSH key at `~/.ssh/id_ed25519`; remote user is `ansible` with passwordless sudo
