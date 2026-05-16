# Ansible Autoserver — Air-Gapped VM Deployment

**Purpose:** Ubuntu-based Ansible control node + local OVA/ISO content server for deploying and configuring Windows Server and RHEL/Rocky VMs against a standalone ESXi host in a closed/air-gapped network.

---

## Table of Contents

- [Architecture](#architecture)
- [VM Spec](#vm-spec)
- [Directory Structure](#directory-structure)
- [Bootstrap Script](#bootstrap-script)
- [Pre-Export Checklist](#pre-export-checklist)
- [Inventory](#inventory)
- [Group Variables](#group-variables)
- [Chrony Template](#chrony-template)
- [Playbook — Deploy from OVA](#playbook--deploy-from-ova)
- [Playbook — Configure RHEL Base](#playbook--configure-rhel-base)
- [Playbook — Configure Windows Base](#playbook--configure-windows-base)
- [WinRM Prep Script](#winrm-prep-script)
- [Quick Reference](#quick-reference)

---

## Architecture

```
Internet-connected network              Air-gapped network
──────────────────────────              ──────────────────
1. Build Ubuntu autoserver VM           5. Deploy OVA to ESXi
2. Run bootstrap.sh (pull all deps)     6. Boot — everything works offline
3. Stage OVAs and ISOs                  7. Run playbooks against deployed VMs
4. Export as OVA
          ──────────────────────────────────────────▶
                       one-way trip

Autoserver roles (single VM):
  ├── Ansible control node      ← runs all playbooks
  ├── nginx HTTP file server    ← serves OVAs/ISOs to ESXi at deploy time
  └── Local content repo        ← stores all OVAs, ISOs, collections, pip wheels
```

**Key design decision:** ESXi's `vmware_deploy_ovf` module can pull OVAs from an HTTP URL. The autoserver's nginx serves `http://autoserver/ova/` directly to ESXi — no file copying, no SCP, no datastore pre-staging required.

---

## VM Spec

| Setting | Value |
|---|---|
| OS | Ubuntu 22.04 LTS Server (not 24.04 — better pyVmomi compat) |
| vCPU | 4 |
| RAM | 8 GB |
| Disk | 1 TB thin provisioned |
| NIC | VMXNET3 — management network (must reach ESXi + deployed VMs) |

### Disk Sizing Reference

| Content | Est. Size |
|---|---|
| Windows Server 2022 OVA | ~8–12 GB |
| RHEL / Rocky 9 OVA | ~3–5 GB |
| NSX-T Manager OVA | ~25 GB |
| Infoblox NIOS OVA | ~15–20 GB |
| Versa VOS OVA | ~3–5 GB |
| Windows Server ISO | ~5–7 GB |
| RHEL ISO | ~10 GB |
| Buffer / future vendors | ~100 GB |

---

## Directory Structure

```
/opt/repo/
├── ova/
│   ├── windows/
│   │   └── windows-server-2022.ova
│   ├── rhel/
│   │   └── rocky-9.4.ova
│   └── vendor/
│       ├── infoblox-nios-9.0.ova
│       ├── nsx-manager-4.x.ova
│       └── versa-vos-22.x.ova
├── iso/
│   ├── windows-server-2022.iso
│   └── rhel-9.4-x86_64-dvd.iso
├── collections/          ← offline .tar.gz ansible collections
├── pip-cache/            ← offline pip wheels
├── apt-cache/            ← offline .deb packages
└── playbooks/
    ├── deploy-from-ova.yml
    ├── configure-rhel-base.yml
    ├── configure-windows-base.yml
    ├── inventory/
    │   └── hosts.yml
    ├── group_vars/
    │   ├── all.yml
    │   ├── rhel.yml
    │   └── windows.yml
    ├── templates/
    │   └── chrony.conf.j2
    └── roles/             ← future role-based expansion
```

---

## Bootstrap Script

Run **once** on the internet-connected VM before OVA export. Pulls all dependencies, stages collections and pip wheels for offline use, and configures nginx.

> **You do not need to create any directories before running this script.** The first thing it does is create the full `/opt/repo/` tree. Just copy the script onto a fresh Ubuntu 22.04 VM and run it as root:
> ```bash
> sudo bash bootstrap.sh
> ```

```bash
#!/bin/bash
# /opt/repo/bootstrap.sh
# Run as root on internet-connected network before OVA export
set -e

# ── Create full directory tree first ─────────────────────────────────────────
# Done at the top so every subsequent step has its target directory ready.
echo "=== Creating directory structure ==="
mkdir -p /opt/repo/{ova/{windows,rhel,vendor},iso,pip-cache,collections,apt-cache}
mkdir -p /opt/repo/playbooks/{inventory,group_vars,templates,roles}

echo "=== Installing system packages ==="
apt-get update
apt-get install -y \
  ansible \
  python3-pip \
  python3-venv \
  nginx \
  nfs-kernel-server \
  git \
  curl \
  wget \
  unzip \
  sshpass \
  tree \
  jq

echo "=== Installing Python dependencies ==="
pip3 install --break-system-packages \
  pyVmomi \
  pywinrm \
  requests \
  requests-credssp \
  requests-kerberos \
  requests-ntlm

echo "=== Caching pip wheels for offline use ==="
pip3 download \
  pyVmomi pywinrm requests requests-credssp \
  requests-kerberos requests-ntlm \
  -d /opt/repo/pip-cache

echo "=== Installing Ansible collections ==="
ansible-galaxy collection install \
  community.vmware \
  ansible.windows \
  community.windows \
  ansible.posix \
  community.general \
  microsoft.ad

echo "=== Downloading collections for offline install ==="
ansible-galaxy collection download \
  community.vmware \
  ansible.windows \
  community.windows \
  ansible.posix \
  community.general \
  microsoft.ad \
  -p /opt/repo/collections

echo "=== Caching apt packages for offline use ==="
apt-get install -y --download-only \
  ansible python3-pip nginx nfs-kernel-server \
  -o Dir::Cache::archives=/opt/repo/apt-cache

echo "=== Configuring nginx ==="
cat > /etc/nginx/sites-available/repo << 'EOF'
server {
    listen 80;
    server_name _;
    root /opt/repo;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location /ova/ {
        add_header Content-Disposition 'attachment';
    }

    location /iso/ {
        add_header Content-Disposition 'attachment';
    }
}
EOF

ln -sf /etc/nginx/sites-available/repo /etc/nginx/sites-enabled/repo
rm -f /etc/nginx/sites-enabled/default
systemctl enable nginx
systemctl restart nginx

echo "=== Writing ansible.cfg ==="
cat > /etc/ansible/ansible.cfg << 'EOF'
[defaults]
inventory           = /opt/repo/playbooks/inventory
collections_path    = ~/.ansible/collections:/opt/repo/collections
roles_path          = /opt/repo/playbooks/roles
host_key_checking   = False
retry_files_enabled = False
stdout_callback     = yaml
interpreter_python  = auto_silent

[ssh_connection]
pipelining          = True
ssh_args            = -o ControlMaster=auto -o ControlPersist=60s
EOF

echo "=== Setting permissions ==="
chmod -R 755 /opt/repo
chown -R www-data:www-data /opt/repo/ova /opt/repo/iso

echo ""
echo "=== Bootstrap complete ==="
echo "Next: copy OVAs to /opt/repo/ova/, ISOs to /opt/repo/iso/"
echo "Then verify: curl http://localhost/ova/"
echo "Then export this VM as OVA."
```

---

## Pre-Export Checklist

Before exporting the autoserver as OVA, verify everything is staged:

```
[ ] bootstrap.sh completed with no errors
[ ] ansible --version returns current version
[ ] ansible-galaxy collection list shows all 6 collections
[ ] pip3 show pyVmomi returns installed
[ ] nginx serving http://localhost/ova/ (curl test)
[ ] nginx serving http://localhost/iso/ (curl test)
[ ] /opt/repo/collections/ has .tar.gz for all collections
[ ] /opt/repo/pip-cache/ has all pip wheels
[ ] /opt/repo/apt-cache/ has .deb files
[ ] All OVAs copied to /opt/repo/ova/
[ ] All ISOs copied to /opt/repo/iso/
[ ] Ansible SSH key generated (~/.ssh/ansible_id_rsa)
[ ] Playbooks copied to /opt/repo/playbooks/
[ ] Snapshot VM (safety net before export)
[ ] Export as OVA from vSphere client
```

---

## Inventory

**`/opt/repo/playbooks/inventory/hosts.yml`**

```yaml
all:
  children:

    esxi:
      hosts:
        esxi-host-01:
          ansible_host: 192.168.1.10
      vars:
        ansible_connection: local

    rhel:
      hosts:
        # Add RHEL/Rocky VMs here as deployed
        # rhel-vm-01:
        #   ansible_host: 192.168.1.101
      vars:
        ansible_user: ansible
        ansible_ssh_private_key_file: ~/.ssh/ansible_id_rsa
        ansible_become: true
        ansible_become_method: sudo

    windows:
      hosts:
        # Add Windows VMs here as deployed
        # win-vm-01:
        #   ansible_host: 192.168.1.201
      vars:
        ansible_connection: winrm
        ansible_winrm_transport: ntlm
        ansible_winrm_server_cert_validation: ignore
        ansible_port: 5985
        ansible_user: ansible-svc
        ansible_password: "{{ vault_windows_ansible_pass }}"
        ansible_winrm_operation_timeout_sec: 120
        ansible_winrm_read_timeout_sec: 150
```

---

## Group Variables

**`/opt/repo/playbooks/group_vars/all.yml`**

```yaml
# ESXi connection — encrypt values with ansible-vault
vault_esxi_host:     "192.168.1.10"
vault_esxi_user:     "root"
vault_esxi_password: "changeme"   # ansible-vault encrypt_string

# Internal NTP — point at DC or GPS NTP source in air-gapped env
internal_ntp_server: "192.168.1.1"
```

**`/opt/repo/playbooks/group_vars/rhel.yml`**

```yaml
vm_timezone: "America/New_York"
ansible_service_user: "ansible"
ansible_ssh_pub_key: "{{ lookup('file', '~/.ssh/ansible_id_rsa.pub') }}"

firewall_allowed_services:
  - ssh
firewall_allowed_ports: []
```

**`/opt/repo/playbooks/group_vars/windows.yml`**

```yaml
vault_windows_ansible_pass: "changeme"   # ansible-vault encrypt_string
vm_timezone: "Eastern Standard Time"
enable_rdp: true
domain_join: false
local_ansible_user: "ansible-svc"
local_ansible_pass: "{{ vault_windows_ansible_pass }}"
```

---

## Chrony Template

**`/opt/repo/playbooks/templates/chrony.conf.j2`**

```
{% for server in ntp_servers %}
server {{ server }} iburst
{% endfor %}

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
```

---

## Playbook — Deploy from OVA

**`/opt/repo/playbooks/deploy-from-ova.yml`**

```yaml
---
# Deploys a VM from OVA served by local nginx to standalone ESXi
#
# Usage:
#   ansible-playbook deploy-from-ova.yml \
#     -e "vm_name=infoblox-01 ova_file=vendor/infoblox-nios-9.0.ova \
#         network=VM-Network datastore=datastore1"

- name: Deploy VM from OVA to standalone ESXi
  hosts: localhost
  gather_facts: false
  connection: local

  vars:
    esxi_host:     "{{ vault_esxi_host }}"
    esxi_user:     "{{ vault_esxi_user }}"
    esxi_password: "{{ vault_esxi_password }}"
    repo_base_url: "http://{{ ansible_default_ipv4.address | default('autoserver') }}/ova"
    vm_disk_mode:  "thin"
    power_on:      true

  tasks:

    - name: Validate required variables
      ansible.builtin.assert:
        that:
          - vm_name is defined and vm_name | length > 0
          - ova_file is defined and ova_file | length > 0
          - datastore is defined and datastore | length > 0
          - network is defined and network | length > 0
        fail_msg: "Pass vm_name, ova_file, datastore, and network via -e"

    - name: Check OVA exists locally
      ansible.builtin.stat:
        path: "/opt/repo/ova/{{ ova_file }}"
      register: ova_stat

    - name: Abort if OVA not found
      ansible.builtin.fail:
        msg: "OVA not found at /opt/repo/ova/{{ ova_file }}"
      when: not ova_stat.stat.exists

    - name: Deploy OVA to ESXi
      community.vmware.vmware_deploy_ovf:
        hostname:        "{{ esxi_host }}"
        username:        "{{ esxi_user }}"
        password:        "{{ esxi_password }}"
        validate_certs:  false
        name:            "{{ vm_name }}"
        datastore:       "{{ datastore }}"
        networks:
          "VM Network":  "{{ network }}"
        ovf:             "{{ repo_base_url }}/{{ ova_file }}"
        disk_provisioning: "{{ vm_disk_mode }}"
        power_on:        "{{ power_on }}"
        wait_for_ip_address: "{{ power_on }}"
      register: deploy_result

    - name: Display deployment result
      ansible.builtin.debug:
        msg:
          - "VM '{{ vm_name }}' deployed successfully"
          - "Power state: {{ deploy_result.instance.hw_power_status | default('unknown') }}"
          - "IP address:  {{ deploy_result.instance.ipv4 | default('pending') }}"

    - name: Add deployed VM to in-memory inventory
      ansible.builtin.add_host:
        name:         "{{ vm_name }}"
        ansible_host: "{{ deploy_result.instance.ipv4 | default(omit) }}"
        groups:       "freshly_deployed"
      when:
        - power_on | bool
        - deploy_result.instance.ipv4 is defined
```

---

## Playbook — Configure RHEL Base

**`/opt/repo/playbooks/configure-rhel-base.yml`**

```yaml
---
# Post-deploy base hardening for RHEL / Rocky Linux VMs
#
# Usage:
#   ansible-playbook configure-rhel-base.yml -i inventory/hosts.yml -l rhel-vm-01

- name: Configure RHEL/Rocky base
  hosts: "{{ target | default('rhel') }}"
  gather_facts: true
  become: true

  vars:
    vm_hostname:        "{{ inventory_hostname }}"
    vm_timezone:        "America/New_York"
    ntp_servers:
      - "{{ internal_ntp_server | default('pool.ntp.org') }}"
    ansible_service_user: "ansible"
    ansible_ssh_pub_key:  "{{ lookup('file', '~/.ssh/ansible_id_rsa.pub') }}"
    base_packages:
      - vim
      - curl
      - wget
      - net-tools
      - bind-utils
      - chrony
      - policycoreutils
      - policycoreutils-python-utils
      - setools-console
      - lsof
      - tcpdump
      - traceroute
      - openssl
      - tar
      - unzip
      - bash-completion
      - python3
      - python3-pip
    firewall_allowed_services:
      - ssh
    firewall_allowed_ports: []

  tasks:

    - name: Set hostname
      ansible.builtin.hostname:
        name: "{{ vm_hostname }}"

    - name: Update /etc/hosts
      ansible.builtin.lineinfile:
        path: /etc/hosts
        regexp: '^127\.0\.1\.1'
        line: "127.0.1.1  {{ vm_hostname }}"

    - name: Set timezone
      community.general.timezone:
        name: "{{ vm_timezone }}"

    - name: Install base packages
      ansible.builtin.dnf:
        name: "{{ base_packages }}"
        state: present

    - name: Configure chrony
      ansible.builtin.template:
        src: templates/chrony.conf.j2
        dest: /etc/chrony.conf
        owner: root
        group: root
        mode: '0644'
      notify: restart chronyd

    - name: Enable chronyd
      ansible.builtin.systemd:
        name: chronyd
        state: started
        enabled: true

    - name: Create ansible service account
      ansible.builtin.user:
        name: "{{ ansible_service_user }}"
        comment: "Ansible Service Account"
        shell: /bin/bash
        create_home: true
        state: present

    - name: Add ansible user to sudoers (NOPASSWD)
      ansible.builtin.copy:
        dest: "/etc/sudoers.d/{{ ansible_service_user }}"
        content: "{{ ansible_service_user }} ALL=(ALL) NOPASSWD: ALL\n"
        owner: root
        group: root
        mode: '0440'
        validate: 'visudo -cf %s'

    - name: Set up SSH authorized key
      ansible.posix.authorized_key:
        user: "{{ ansible_service_user }}"
        state: present
        key: "{{ ansible_ssh_pub_key }}"

    - name: Harden SSH configuration
      ansible.builtin.lineinfile:
        path: /etc/ssh/sshd_config
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
        validate: 'sshd -t -f %s'
      loop:
        - { regexp: '^#?PermitRootLogin',        line: 'PermitRootLogin no' }
        - { regexp: '^#?PasswordAuthentication',  line: 'PasswordAuthentication no' }
        - { regexp: '^#?X11Forwarding',           line: 'X11Forwarding no' }
        - { regexp: '^#?MaxAuthTries',             line: 'MaxAuthTries 4' }
        - { regexp: '^#?ClientAliveInterval',      line: 'ClientAliveInterval 300' }
        - { regexp: '^#?ClientAliveCountMax',      line: 'ClientAliveCountMax 2' }
        - { regexp: '^#?AllowAgentForwarding',     line: 'AllowAgentForwarding no' }
        - { regexp: '^#?Protocol',                 line: 'Protocol 2' }
      notify: restart sshd

    - name: Ensure SELinux is enforcing
      ansible.posix.selinux:
        policy: targeted
        state: enforcing
      register: selinux_result

    - name: Note if reboot required for SELinux
      ansible.builtin.debug:
        msg: "SELinux state changed — reboot required"
      when: selinux_result.reboot_required | default(false)

    - name: Ensure firewalld running
      ansible.builtin.systemd:
        name: firewalld
        state: started
        enabled: true

    - name: Allow services through firewall
      ansible.posix.firewalld:
        service: "{{ item }}"
        permanent: true
        state: enabled
        immediate: true
      loop: "{{ firewall_allowed_services }}"

    - name: Allow ports through firewall
      ansible.posix.firewalld:
        port: "{{ item }}"
        permanent: true
        state: enabled
        immediate: true
      loop: "{{ firewall_allowed_ports }}"
      when: firewall_allowed_ports | length > 0

    - name: Disable unnecessary services
      ansible.builtin.systemd:
        name: "{{ item }}"
        state: stopped
        enabled: false
      loop:
        - bluetooth
        - avahi-daemon
        - cups
      failed_when: false

    - name: Display VM summary
      ansible.builtin.debug:
        msg:
          - "Hostname: {{ ansible_hostname }}"
          - "OS:       {{ ansible_distribution }} {{ ansible_distribution_version }}"
          - "IP:       {{ ansible_default_ipv4.address | default('N/A') }}"
          - "SELinux:  {{ ansible_selinux.status | default('unknown') }}"

  handlers:
    - name: restart sshd
      ansible.builtin.systemd:
        name: sshd
        state: restarted

    - name: restart chronyd
      ansible.builtin.systemd:
        name: chronyd
        state: restarted
```

---

## Playbook — Configure Windows Base

**`/opt/repo/playbooks/configure-windows-base.yml`**

```yaml
---
# Post-deploy base configuration for Windows Server VMs
# Requires WinRM enabled on OVA template — see WinRM Prep Script below
#
# Usage:
#   ansible-playbook configure-windows-base.yml -i inventory/hosts.yml -l win-vm-01

- name: Configure Windows Server base
  hosts: "{{ target | default('windows') }}"
  gather_facts: true

  vars:
    vm_hostname:         "{{ inventory_hostname }}"
    vm_timezone:         "Eastern Standard Time"
    enable_rdp:          true
    domain_join:         false
    domain_name:         ""
    domain_admin_user:   ""
    domain_admin_pass:   ""
    local_ansible_user:  "ansible-svc"
    local_ansible_pass:  "{{ vault_windows_ansible_pass }}"
    services_to_disable:
      - wuauserv
      - UsoSvc
      - WaaSMedicSvc
      - DiagTrack
      - dmwappushservice
      - XblAuthManager
      - XblGameSave
      - XboxNetApiSvc

  tasks:

    - name: Set computer name
      ansible.windows.win_hostname:
        name: "{{ vm_hostname }}"
      register: hostname_result

    - name: Reboot if hostname changed
      ansible.windows.win_reboot:
        reboot_timeout: 300
        post_reboot_delay: 30
      when: hostname_result.reboot_required

    - name: Set timezone
      community.windows.win_timezone:
        timezone: "{{ vm_timezone }}"

    - name: Create local ansible service account
      ansible.windows.win_user:
        name: "{{ local_ansible_user }}"
        password: "{{ local_ansible_pass }}"
        password_never_expires: true
        user_cannot_change_password: true
        account_disabled: false
        state: present
        description: "Ansible Service Account — do not delete"

    - name: Add ansible account to local Administrators
      ansible.windows.win_group_membership:
        name: Administrators
        members:
          - "{{ local_ansible_user }}"
        state: present

    - name: Ensure WinRM running
      ansible.windows.win_service:
        name: WinRM
        state: started
        start_mode: auto

    - name: Configure WinRM HTTPS listener
      ansible.windows.win_powershell:
        script: |
          Remove-WSManInstance winrm/config/Listener -SelectorSet @{Transport='HTTPS';Address='*'} -ErrorAction SilentlyContinue
          $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME `
            -CertStoreLocation 'cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(5)
          New-WSManInstance winrm/config/Listener `
            -SelectorSet @{Transport='HTTPS';Address='*'} `
            -ValueSet @{Hostname=$env:COMPUTERNAME;CertificateThumbprint=$cert.Thumbprint}
          Set-WSManInstance -ResourceURI winrm/config -ValueSet @{MaxTimeoutms=1800000}

    - name: Open WinRM ports in firewall
      ansible.windows.win_firewall_rule:
        name: "{{ item.name }}"
        localport: "{{ item.port }}"
        action: allow
        direction: in
        protocol: tcp
        state: present
        enabled: true
      loop:
        - { name: "WinRM HTTP",  port: "5985" }
        - { name: "WinRM HTTPS", port: "5986" }

    - name: Set power plan to High Performance
      ansible.windows.win_powershell:
        script: |
          $hp = Get-CimInstance -Namespace root/cimv2/power -ClassName Win32_PowerPlan |
                Where-Object { $_.ElementName -eq 'High Performance' }
          if ($hp) { Invoke-CimMethod -InputObject $hp -MethodName Activate }

    - name: Set PageFile to system managed
      ansible.windows.win_powershell:
        script: |
          $cs = Get-CimInstance Win32_ComputerSystem
          if (-not $cs.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$true}
          }

    - name: Disable unnecessary services
      ansible.windows.win_service:
        name: "{{ item }}"
        state: stopped
        start_mode: disabled
      loop: "{{ services_to_disable }}"
      failed_when: false

    - name: Enable Windows Firewall on all profiles
      community.windows.win_firewall:
        profiles: [Domain, Private, Public]
        state: enabled
        inbound_action: block
        outbound_action: allow

    - name: Allow ICMP inbound
      ansible.windows.win_firewall_rule:
        name: "Allow ICMPv4 Inbound"
        protocol: icmpv4
        action: allow
        direction: in
        state: present
        enabled: true

    - name: Enable RDP
      ansible.windows.win_regedit:
        path: HKLM:\System\CurrentControlSet\Control\Terminal Server
        name: fDenyTSConnections
        data: 0
        type: dword
      when: enable_rdp | bool

    - name: Open RDP firewall rule
      ansible.windows.win_firewall_rule:
        name: "Remote Desktop"
        localport: "3389"
        action: allow
        direction: in
        protocol: tcp
        state: present
        enabled: true
      when: enable_rdp | bool

    - name: Join domain
      microsoft.ad.membership:
        dns_domain_name:    "{{ domain_name }}"
        domain_admin_user:  "{{ domain_admin_user }}"
        domain_admin_password: "{{ domain_admin_pass }}"
        state: domain
      register: domain_result
      when: domain_join | bool

    - name: Reboot after domain join
      ansible.windows.win_reboot:
        reboot_timeout: 300
        post_reboot_delay: 60
      when:
        - domain_join | bool
        - domain_result.reboot_required | default(false)

    - name: Display VM summary
      ansible.windows.win_powershell:
        script: |
          $os  = Get-CimInstance Win32_OperatingSystem
          $net = Get-NetIPAddress -AddressFamily IPv4 |
                 Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select -First 1
          Write-Host "Hostname: $env:COMPUTERNAME"
          Write-Host "OS:       $($os.Caption)"
          Write-Host "IP:       $($net.IPAddress)"
          Write-Host "Domain:   $(if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { 'WORKGROUP' })"
      register: summary

    - name: Show summary
      ansible.builtin.debug:
        msg: "{{ summary.output }}"
```

---

## WinRM Prep Script

Run this **on the Windows Server VM before exporting as OVA**. Do it once — every VM deployed from that OVA will have WinRM ready for Ansible on first boot.

**`scripts/winrm-prep.ps1`**

```powershell
# Run as Administrator before OVA export
Write-Host "Configuring WinRM for Ansible management..." -ForegroundColor Cyan

Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service WinRM -StartupType Automatic

Set-Item WSMan:\localhost\Service\AllowUnencrypted $true
Set-Item WSMan:\localhost\Service\Auth\Basic $true
Set-Item WSMan:\localhost\MaxTimeoutms 1800000

netsh advfirewall firewall add rule name="WinRM HTTP"  protocol=TCP dir=in localport=5985 action=allow
netsh advfirewall firewall add rule name="WinRM HTTPS" protocol=TCP dir=in localport=5986 action=allow

Write-Host "`nWinRM listeners:" -ForegroundColor Green
winrm enumerate winrm/config/Listener

Write-Host "`nDone. Shut down and export as OVA." -ForegroundColor Green
```

---

## Quick Reference

### Initial Setup (autoserver first boot on closed network)

```bash
# Generate Ansible SSH key
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ansible_id_rsa -N ""

# Encrypt secrets
ansible-vault encrypt_string 'your-esxi-password'    --name 'vault_esxi_password'
ansible-vault encrypt_string 'your-windows-password' --name 'vault_windows_ansible_pass'
# Paste output into group_vars/all.yml and group_vars/windows.yml

# Verify nginx is serving content
curl http://localhost/ova/
curl http://localhost/iso/

# Install collections offline (if not already installed)
ansible-galaxy collection install /opt/repo/collections/community-vmware-*.tar.gz --offline
ansible-galaxy collection install /opt/repo/collections/ansible-windows-*.tar.gz --offline
```

### Deploy a VM

```bash
# RHEL / Rocky
ansible-playbook deploy-from-ova.yml \
  -e "vm_name=rhel-01 ova_file=rhel/rocky-9.4.ova datastore=datastore1 network=VM-Network" \
  --ask-vault-pass

# Windows Server
ansible-playbook deploy-from-ova.yml \
  -e "vm_name=win-01 ova_file=windows/windows-server-2022.ova datastore=datastore1 network=VM-Network" \
  --ask-vault-pass

# Vendor appliance (Infoblox, NSX-T, Versa, etc.)
ansible-playbook deploy-from-ova.yml \
  -e "vm_name=infoblox-01 ova_file=vendor/infoblox-nios-9.0.ova datastore=datastore1 network=VM-Network" \
  --ask-vault-pass
```

### Configure Deployed VMs

```bash
# Configure RHEL VM
ansible-playbook configure-rhel-base.yml -i inventory/hosts.yml -l rhel-01 --ask-vault-pass

# Configure Windows VM
ansible-playbook configure-windows-base.yml -i inventory/hosts.yml -l win-01 --ask-vault-pass

# Test connectivity
ansible rhel    -i inventory/hosts.yml -m ansible.builtin.ping
ansible windows -i inventory/hosts.yml -m ansible.windows.win_ping --ask-vault-pass
```

### Offline Package Install (if needed post air-gap)

```bash
# Install pip package from local cache
pip3 install --no-index --find-links=/opt/repo/pip-cache pyVmomi

# Install apt package from local cache
dpkg -i /opt/repo/apt-cache/package-name.deb

# Install Ansible collection offline
ansible-galaxy collection install /opt/repo/collections/community-vmware-4.x.tar.gz --offline
```

### Add a New VM to Inventory

Edit `/opt/repo/playbooks/inventory/hosts.yml` and add under the appropriate group:

```yaml
rhel:
  hosts:
    rhel-vm-02:
      ansible_host: 192.168.1.102

windows:
  hosts:
    win-vm-02:
      ansible_host: 192.168.1.202
```

---

*Last updated: May 2026*
*Maintainer: Wisebird Holdings LLC / FalconRock Consulting*
