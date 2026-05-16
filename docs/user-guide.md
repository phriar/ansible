# User Guide

Practical reference for working with this repo day-to-day — where things live, how to run playbooks, how to manage secrets, and how to add new VMs, playbooks, or roles.

---

## Folder Structure

```
/opt/repo/playbooks/               ← clone the repo here on the autoserver
│                                    (on your Mac: ~/Documents/Ansible/)
├── ansible.cfg                    ← Ansible reads this automatically when you
│                                    run commands from this directory
├── requirements.yml               ← Galaxy collections to install
│
├── autoserver/                    ← everything lives here
│   ├── bootstrap.sh               ← run once to set up a fresh Ubuntu VM
│   │
│   ├── inventory/                 ← Ansible inventory (hosts + variables)
│   │   ├── hosts.yml              ← list of all hosts and groups
│   │   ├── host_vars/             ← per-host variable overrides (create as needed)
│   │   │   └── rocky-01.yml       ← example: variables only for rocky-01
│   │   └── group_vars/
│   │       └── all/
│   │           ├── vars.yml       ← non-secret variables (IPs, URLs, settings)
│   │           ├── vault.yml      ← SECRETS — encrypted, never commit unencrypted
│   │           └── vm_catalog.yml ← VM deployment specs (disk, RAM, CPU, IP, OVA)
│   │
│   ├── deploy-esxi.yml            ← deploy VMs to standalone ESXi
│   ├── deploy-vcenter.yml         ← deploy VMs to vCenter
│   ├── deploy-vm-template.yml     ← clone a VM from a vCenter template
│   ├── configure-rhel-base.yml    ← post-deploy config for RHEL/Rocky VMs
│   ├── configure-windows-base.yml ← post-deploy config for Windows VMs
│   │
│   ├── vars/                      ← playbook-specific variable files
│   │   └── deploy-vm-template.yml ← variables for the template-clone playbook
│   │
│   ├── templates/                 ← Jinja2 templates (.j2) rendered onto hosts
│   └── roles/                     ← reusable roles (see "Adding a Role" below)
│
└── docs/                          ← reference documentation
    ├── user-guide.md              ← this file
    ├── autoserver-design.md       ← full architecture and design decisions
    └── windows-domain-join.md     ← domain join runbook
```

---

## Where to Run Commands From

**Always run `ansible-playbook` from the repo root** — the directory that contains `ansible.cfg`.

```
On the autoserver:   cd /opt/repo/playbooks
On your Mac:         cd ~/Documents/Ansible
```

Ansible finds `ansible.cfg` only in the exact directory you run from (it does not search parent directories). Running from the wrong directory means it won't find the inventory and commands will fail.

```bash
# Correct
cd /opt/repo/playbooks
ansible-playbook autoserver/deploy-esxi.yml --ask-vault-pass

# Wrong — ansible.cfg is not in this directory
cd /opt/repo/playbooks/autoserver
ansible-playbook deploy-esxi.yml --ask-vault-pass
```

---

## Vault — Managing Secrets

### Where it lives

```
autoserver/inventory/group_vars/all/vault.yml
```

This file holds all passwords and secrets. It is **gitignored when unencrypted** — you must encrypt it before committing, and it must exist (even if encrypted) on every machine you run playbooks from.

### Naming convention

Every variable in `vault.yml` starts with `vault_`. The plain variable in `vars.yml` references it:

```yaml
# vault.yml (encrypted)
vault_esxi_password: "your-real-password"

# vars.yml (not encrypted, safe to commit)
esxi_password: "{{ vault_esxi_password }}"
```

This way playbooks always reference the plain name (`esxi_password`) and you can see what variables exist in `vars.yml` without decrypting.

### Common vault commands

```bash
# First time — encrypt the file before committing
ansible-vault encrypt autoserver/inventory/group_vars/all/vault.yml

# Edit secrets in place (keeps file encrypted on disk)
ansible-vault edit autoserver/inventory/group_vars/all/vault.yml

# View without writing to disk
ansible-vault view autoserver/inventory/group_vars/all/vault.yml

# Run a playbook — prompts for vault password
ansible-playbook autoserver/deploy-esxi.yml --ask-vault-pass

# Run without prompt — store password in a file (never commit this file)
echo "your-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
ansible-playbook autoserver/deploy-esxi.yml --vault-password-file ~/.vault_pass
```

### What secrets to put in vault.yml

```yaml
# autoserver/inventory/group_vars/all/vault.yml
vault_esxi_password:        "your-esxi-root-password"
vault_vcenter_password:     "your-vcenter-password"
vault_windows_ansible_pass: "your-windows-service-account-password"
vault_nsx_admin_password:   "your-nsx-admin-password"
vault_nsx_audit_password:   "your-nsx-audit-password"
```

---

## Inventory — Adding Hosts

### hosts.yml — registering a deployed VM

After you deploy a VM, uncomment its entry in `autoserver/inventory/hosts.yml` so Ansible can connect to it for configuration playbooks:

```yaml
# Before (VM not yet deployed)
rhel:
  hosts:
    # rocky-01:
    #   ansible_host: 192.168.100.101

# After (VM is up)
rhel:
  hosts:
    rocky-01:
      ansible_host: 192.168.100.101
```

The group (`rhel`, `windows`, `vendor`) controls which connection settings apply — SSH for RHEL, WinRM for Windows. Those connection settings are already defined in the `vars:` block for each group in `hosts.yml`, so you only need to add the name and IP.

### Adding a host to a new group

If you have a host type that doesn't fit the existing groups, add a new group to `hosts.yml`:

```yaml
# In hosts.yml, under children:
monitoring:
  hosts:
    grafana-01:
      ansible_host: 192.168.100.60
  vars:
    ansible_user: ansible
    ansible_ssh_private_key_file: ~/.ssh/ansible_id_rsa
    ansible_become: true
```

### host_vars — per-host variable overrides

Use `host_vars` when one host needs a different value than the rest of its group. Create a file named after the host:

```bash
# Create the host_vars directory if it doesn't exist
mkdir -p autoserver/inventory/host_vars

# Create a file for the specific host
touch autoserver/inventory/host_vars/rocky-01.yml
```

```yaml
# autoserver/inventory/host_vars/rocky-01.yml
# These values apply ONLY to rocky-01 and override group_vars
vm_timezone: "America/New_York"
firewall_allowed_ports:
  - "8080/tcp"
  - "9090/tcp"
```

Ansible loads host_vars automatically — no import needed.

---

## vm_catalog.yml — Adding a VM to Deploy

`autoserver/inventory/group_vars/all/vm_catalog.yml` is the source of truth for every VM the deploy playbooks can create. Add an entry here before running `deploy-esxi.yml` or `deploy-vcenter.yml`.

```yaml
# autoserver/inventory/group_vars/all/vm_catalog.yml
vms:

  - name: rocky-02              # VM display name in ESXi/vCenter and OS hostname
    group: rhel                 # rhel | windows | vendor — controls deploy tag
    ova_file: rhel/rocky-9.4.ova  # path relative to /opt/repo/ova/
    datastore: datastore1       # ESXi datastore name
    networks:
      "VM Network": Management  # OVF network name → your port group name
    memory_mb: 8192
    num_cpus: 4
    disk_gb: 100                # resize primary disk; 0 = keep OVA default
    ip: 192.168.100.102
    netmask: 255.255.255.0
    gateway: 192.168.100.1
    power_on: true
    wait_for_ip: true
    vcenter_folder: /Datacenter/vm/RHEL   # vCenter only, ignored for ESXi-direct
```

Then deploy just that VM:

```bash
ansible-playbook autoserver/deploy-esxi.yml -e vm_filter=rocky-02 --ask-vault-pass
```

---

## Running Playbooks

All commands run from the repo root (`/opt/repo/playbooks` on the autoserver).

### Deploy playbooks

```bash
# Deploy every VM in vm_catalog.yml
ansible-playbook autoserver/deploy-esxi.yml --ask-vault-pass

# Deploy one group only
ansible-playbook autoserver/deploy-esxi.yml --tags rhel --ask-vault-pass
ansible-playbook autoserver/deploy-esxi.yml --tags windows --ask-vault-pass
ansible-playbook autoserver/deploy-esxi.yml --tags vendor --ask-vault-pass

# Deploy a single VM by name
ansible-playbook autoserver/deploy-esxi.yml -e vm_filter=infoblox-01 --ask-vault-pass

# Dry run — shows what would change without doing anything
ansible-playbook autoserver/deploy-esxi.yml --check --diff --ask-vault-pass
```

### Configuration playbooks

```bash
# Configure a single RHEL VM after deploying it
ansible-playbook autoserver/configure-rhel-base.yml -l rocky-01 --ask-vault-pass

# Configure all RHEL VMs at once
ansible-playbook autoserver/configure-rhel-base.yml --ask-vault-pass

# Configure a Windows VM
ansible-playbook autoserver/configure-windows-base.yml -l win-server-01 --ask-vault-pass
```

### Test connectivity

```bash
# Ping all RHEL hosts
ansible rhel -m ansible.builtin.ping

# Ping all Windows hosts
ansible windows -m ansible.windows.win_ping --ask-vault-pass

# Ping a specific host
ansible rocky-01 -m ansible.builtin.ping

# Run a one-off command on all RHEL hosts
ansible rhel -m ansible.builtin.command -a "uptime"
```

---

## Adding a New Playbook

Create a `.yml` file directly in `autoserver/`. Convention:

- `deploy-*.yml` — provisions infrastructure (runs against `localhost`, talks to ESXi/vCenter API)
- `configure-*.yml` — configures inside a running VM (runs against the VM over SSH or WinRM)

```yaml
# autoserver/configure-something.yml
---
- name: Do something on RHEL hosts
  hosts: "{{ target | default('rhel') }}"   # -l flag or -e target=rocky-01 to limit
  gather_facts: true
  become: true

  vars:
    some_variable: "default_value"

  tasks:
    - name: Example task
      ansible.builtin.debug:
        msg: "Running on {{ inventory_hostname }}"
```

Run it:

```bash
ansible-playbook autoserver/configure-something.yml -l rocky-01 --ask-vault-pass
```

If the playbook needs variables specific to it (not shared across everything), put them in `autoserver/vars/configure-something.yml` and reference with:

```yaml
  vars_files:
    - vars/configure-something.yml
```

---

## Adding a New Role

Roles are for configuration that you want to reuse across multiple playbooks (e.g. a "postgres" role used by both a standalone DB playbook and a DR playbook).

```bash
# Create the role scaffold
ansible-galaxy role init autoserver/roles/my-role
```

This creates:

```
autoserver/roles/my-role/
├── tasks/main.yml       ← put your tasks here
├── handlers/main.yml    ← services to restart on change
├── defaults/main.yml    ← default variable values (lowest priority, safe to override)
├── vars/main.yml        ← high-priority vars (not meant to be overridden)
├── templates/           ← Jinja2 templates
├── files/               ← static files to copy
└── meta/main.yml        ← role metadata and dependencies
```

Use the role in a playbook:

```yaml
- name: Configure database servers
  hosts: databases
  become: true
  roles:
    - my-role
```

Override a role default for one playbook:

```yaml
  roles:
    - role: my-role
      vars:
        some_default_var: "override_value"
```

---

## Quick Reference

| Task | Command |
|---|---|
| Install collections | `ansible-galaxy collection install -r requirements.yml` |
| Encrypt vault | `ansible-vault encrypt autoserver/inventory/group_vars/all/vault.yml` |
| Edit vault | `ansible-vault edit autoserver/inventory/group_vars/all/vault.yml` |
| Deploy all VMs (ESXi) | `ansible-playbook autoserver/deploy-esxi.yml --ask-vault-pass` |
| Deploy one VM | `ansible-playbook autoserver/deploy-esxi.yml -e vm_filter=<name> --ask-vault-pass` |
| Deploy one group | `ansible-playbook autoserver/deploy-esxi.yml --tags rhel --ask-vault-pass` |
| Configure RHEL VM | `ansible-playbook autoserver/configure-rhel-base.yml -l <host> --ask-vault-pass` |
| Configure Windows VM | `ansible-playbook autoserver/configure-windows-base.yml -l <host> --ask-vault-pass` |
| Ping all RHEL hosts | `ansible rhel -m ansible.builtin.ping` |
| Dry run any playbook | Add `--check --diff` to any command |
| New role scaffold | `ansible-galaxy role init autoserver/roles/<name>` |
