# Ansible Infrastructure

This repository contains Ansible playbooks, roles, and inventories for managing infrastructure across staging and production environments.

---

## Quick start

```bash
# 1. Install required Galaxy collections and roles
ansible-galaxy install -r requirements.yml

# 2. Encrypt the vault file before committing
ansible-vault encrypt group_vars/all/vault.yml

# 3. Dry-run against staging
ansible-playbook -i inventories/staging playbooks/site.yml --check

# 4. Run for real
ansible-playbook -i inventories/production playbooks/site.yml
```

---

## Directory structure

```
.
├── ansible.cfg                 # Global Ansible settings (SSH, privilege escalation, output format)
├── requirements.yml            # Galaxy collections and roles to install before running
├── .gitignore                  # Excludes vault files, .retry files, keys, and certs
│
├── inventories/                # One subdirectory per environment
│   ├── production/
│   │   ├── hosts.ini           # Host groups and connection details for production
│   │   ├── group_vars/         # Variables that apply to all hosts in production
│   │   │   └── all.yml         # Env-specific overrides (env name, NTP, DNS)
│   │   └── host_vars/          # Variables scoped to a single host (add <hostname>.yml files here)
│   └── staging/
│       ├── hosts.ini           # Staging host groups
│       ├── group_vars/
│       │   └── all.yml
│       └── host_vars/
│
├── group_vars/                 # Variables loaded for every host regardless of environment
│   └── all/
│       ├── vars.yml            # Non-sensitive global defaults (packages, sysctl, etc.)
│       └── vault.yml           # Encrypted secrets — MUST be encrypted with ansible-vault
│
├── host_vars/                  # Host-specific variables not tied to a specific inventory
│
├── playbooks/                  # Entry points — what you run with ansible-playbook
│   ├── site.yml                # Master playbook: imports all others in order
│   ├── common.yml              # Applies baseline config (packages, NTP, sysctl) to every host
│   ├── webservers.yml          # Configures the [webservers] group
│   └── databases.yml           # Configures the [databases] group
│
└── roles/                      # Reusable units of configuration
    ├── common/                 # Applied to every host; establishes baseline OS state
    │   ├── tasks/main.yml      # Task list: install packages, set timezone, apply sysctl
    │   ├── handlers/main.yml   # Triggered on change: restart NTP, cron
    │   ├── templates/          # Jinja2 templates rendered onto hosts
    │   │   └── ntp.conf.j2     # NTP config — uses ntp_servers variable
    │   ├── files/              # Static files copied verbatim to hosts
    │   ├── defaults/main.yml   # Role defaults — lowest priority, safe to override anywhere
    │   ├── vars/main.yml       # Role vars — high priority, not intended for override
    │   └── meta/main.yml       # Role metadata: author, platform support, dependencies
    │
    └── webserver/              # Installs and configures nginx
        ├── tasks/main.yml      # Install nginx, deploy configs, enable vhosts, start service
        ├── handlers/main.yml   # Reload/restart nginx on config change
        ├── templates/
        │   ├── nginx.conf.j2   # Main nginx config — uses webserver_worker_* variables
        │   └── vhost.conf.j2   # Per-vhost config — loops over webserver_vhosts list
        ├── files/              # Static assets (certs, custom error pages, etc.)
        ├── defaults/main.yml   # Port, worker settings, vhost list defaults
        ├── vars/main.yml       # High-priority role vars (empty by default)
        └── meta/main.yml       # Declares dependency on the common role
```

---

## Inventories

Switch environments by passing `-i inventories/<env>` to `ansible-playbook`. Variables in `inventories/<env>/group_vars/` override global `group_vars/` for that environment only.

```bash
ansible-playbook -i inventories/staging  playbooks/site.yml
ansible-playbook -i inventories/production playbooks/site.yml
```

To add a new host, edit the relevant `hosts.ini` and optionally add a `host_vars/<hostname>.yml` for host-specific overrides.

---

## Vault (secrets)

All secrets live in `group_vars/all/vault.yml`. The convention is to prefix every vault variable with `vault_` and reference it from a plain var in `vars.yml`:

```yaml
# group_vars/all/vars.yml
db_root_password: "{{ vault_db_root_password }}"

# group_vars/all/vault.yml  (encrypted)
vault_db_root_password: "s3cr3t"
```

Common vault commands:

```bash
# Encrypt (do this before first commit)
ansible-vault encrypt group_vars/all/vault.yml

# View without decrypting to disk
ansible-vault view group_vars/all/vault.yml

# Edit in place
ansible-vault edit group_vars/all/vault.yml

# Run a playbook with vault (will prompt for password)
ansible-playbook playbooks/site.yml --ask-vault-pass

# Or use a password file (don't commit this file)
ansible-playbook playbooks/site.yml --vault-password-file ~/.vault_pass
```

---

## Roles

| Role | Purpose | Key variables |
|---|---|---|
| `common` | Baseline OS config applied to every host | `common_packages`, `timezone`, `ntp_servers`, `sysctl_settings` |
| `webserver` | nginx install + vhost management | `webserver_vhosts`, `webserver_port`, `webserver_worker_processes` |

### Adding a new role

```bash
ansible-galaxy role init roles/<role_name>
```

Then add it to the appropriate playbook under `roles:`.

---

## Running specific parts

```bash
# Only run tasks tagged "packages"
ansible-playbook playbooks/site.yml --tags packages

# Only target one host
ansible-playbook playbooks/site.yml --limit web01.example.com

# Dry-run with diff
ansible-playbook playbooks/site.yml --check --diff
```

---

## Requirements

- Ansible >= 2.14
- Python >= 3.9 on control node
- `ansible-galaxy install -r requirements.yml` run before first use
