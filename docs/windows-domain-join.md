# Ansible — Windows Server Domain Join Runbook

**Domain:** `poseidon.local`
**Ansible Collection:** `microsoft.ad`
**Connection:** WinRM (NTLM pre-join → Kerberos post-join)

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step 1 — Network & DNS](#step-1--network--dns)
- [Step 2 — Time Sync](#step-2--time-sync)
- [Step 3 — Firewall Ports](#step-3--firewall-ports)
- [Step 4 — AD Prerequisites](#step-4--ad-prerequisites)
- [Step 5 — Ansible Credentials](#step-5--ansible-credentials)
- [Step 6 — Inventory Configuration](#step-6--inventory-configuration)
- [Step 7 — Domain Join Playbook](#step-7--domain-join-playbook)
- [Step 8 — Post-Join Verification](#step-8--post-join-verification)
- [Troubleshooting](#troubleshooting)
- [Full Pipeline — Deploy + Join](#full-pipeline--deploy--join)

---

## Overview

What has to happen in order for Ansible to successfully join a Windows Server to `poseidon.local`:

```
New VM boots
    │
    ├─ 1. VM can reach a DC on the network
    ├─ 2. VM's DNS points at a DC (resolves poseidon.local)
    ├─ 3. VM clock is within 5 minutes of DC (Kerberos requirement)
    ├─ 4. WinRM is running (already handled by OVA template)
    ├─ 5. Ansible has domain admin credentials (vaulted)
    │
    └─ ansible-playbook domain-join.yml
           │
           ├─ Sets DNS to DC IP
           ├─ Calls microsoft.ad.membership
           ├─ Reboots VM
           └─ VM is domain member ✓
```

The most common failure point is **DNS**. If the VM can't resolve `poseidon.local`, the join fails before it even tries credentials.

---

## Prerequisites

### On the Ansible Autoserver

```bash
# Verify microsoft.ad collection is installed
ansible-galaxy collection list | grep microsoft.ad

# If not installed (online)
ansible-galaxy collection install microsoft.ad

# If air-gapped — install from local cache
ansible-galaxy collection install /opt/repo/collections/microsoft-ad-*.tar.gz --offline

# Verify pywinrm is installed (required for WinRM connection)
pip3 show pywinrm
```

### On the Windows VM (OVA template — already done if you ran winrm-prep.ps1)

- WinRM enabled and running on port 5985
- Local administrator account that Ansible can connect with
- PowerShell execution policy not blocking scripts

### In Active Directory

- Service account or domain admin credentials for joining computers
- Target OU exists (if you're placing computers in a specific OU)
- DNS A record will be created automatically on join — no pre-staging needed

---

## Step 1 — Network & DNS

This is the most critical step. The VM **must** use a DC as its DNS server before the domain join runs. Do not rely on DHCP to hand out the right DNS — set it explicitly in the playbook.

### Find your DC IPs

```powershell
# Run on any existing domain member or the DC itself
nslookup poseidon.local
# or
Resolve-DnsName poseidon.local
```

Note both your primary and secondary DC IPs. You'll need them as variables.

### What Ansible will set on the target VM

```
DNS Server 1: <primary DC IP>    e.g. 192.168.1.10
DNS Server 2: <secondary DC IP>  e.g. 192.168.1.11  (if you have one)
```

The playbook sets this via `ansible.windows.win_dns_client` before attempting the join.

---

## Step 2 — Time Sync

Kerberos authentication (used during domain join) requires the VM clock to be within **5 minutes** of the DC. If it's not, the join fails with a cryptic error.

### Verify time sync is configured on your OVA template

The base Windows playbook already disables `wuauserv` but does not configure NTP. For domain-joined machines, Windows will sync to the DC automatically **after** the join. The problem is **before** the join.

**Options:**

**Option A — VMware Tools time sync (simplest)**
Enable host-based time sync in VMware Tools. The VM syncs to the ESXi host clock. Make sure your ESXi host has accurate time.

```powershell
# Verify VMware Tools time sync is enabled (run on VM)
Get-ItemProperty "HKLM:\SOFTWARE\VMware, Inc.\VMware Tools" | Select-Object *time*
```

**Option B — Point at internal NTP before join**
The domain join playbook sets a temporary NTP source before joining:

```powershell
w32tm /config /manualpeerlist:"192.168.1.10" /syncfromflags:manual /reliable:yes /update
w32tm /resync /force
```

After the join, Windows automatically syncs from the DC hierarchy — no further NTP config needed.

---

## Step 3 — Firewall Ports

The **VM's Windows firewall** is handled by the playbook. But make sure your **network** (NSX-T segments, physical switches, ESXi port groups) allows these ports from the new VM to the DC:

| Port | Protocol | Purpose |
|---|---|---|
| 53 | TCP/UDP | DNS |
| 88 | TCP/UDP | Kerberos |
| 135 | TCP | RPC Endpoint Mapper |
| 137-139 | UDP | NetBIOS |
| 389 | TCP/UDP | LDAP |
| 445 | TCP | SMB (used during join) |
| 464 | TCP/UDP | Kerberos password change |
| 636 | TCP | LDAPS (optional) |
| 3268 | TCP | Global Catalog |
| 49152-65535 | TCP | RPC Dynamic Ports |

> **NSX-T note:** If this VM is on an isolated segment with SNAT, make sure your T1 SNAT rule allows traffic from the VM subnet to the DC subnet on these ports. The domain join itself initiates from the VM outbound to the DC — it's not just DNS.

---

## Step 4 — AD Prerequisites

### Create a dedicated OU for Ansible-joined computers (recommended)

```powershell
# Run on DC or any machine with AD PowerShell module
New-ADOrganizationalUnit -Name "Ansible-Managed" `
  -Path "DC=poseidon,DC=local" `
  -Description "VMs deployed and managed by Ansible"
```

### Option A — Use a domain admin account (simplest for lab/dev)

Just vault your domain admin credentials. Fine for a closed/cleared environment.

### Option B — Delegate join permissions to a service account (production best practice)

```powershell
# Create a dedicated join account
New-ADUser -Name "svc-ansible-join" `
  -SamAccountName "svc-ansible-join" `
  -UserPrincipalName "svc-ansible-join@poseidon.local" `
  -AccountPassword (ConvertTo-SecureString "StrongPassword123!" -AsPlainText -Force) `
  -PasswordNeverExpires $true `
  -CannotChangePassword $true `
  -Enabled $true

# Delegate "Join computers to domain" to this account on target OU
# Run in ADUC or via dsacls:
dsacls "OU=Ansible-Managed,DC=poseidon,DC=local" /G "poseidon\svc-ansible-join:CC;Computer"
dsacls "OU=Ansible-Managed,DC=poseidon,DC=local" /G "poseidon\svc-ansible-join:WP;*;Computer"
```

With this account you don't need domain admin rights — it can only join computers to that specific OU.

---

## Step 5 — Ansible Credentials

Store all domain credentials in ansible-vault. Never plaintext in playbooks or group_vars.

```bash
# On the autoserver — encrypt your domain join password
ansible-vault encrypt_string 'YourDomainAdminPassword' --name 'vault_domain_join_pass'

# Paste the output into group_vars/windows.yml
```

**`group_vars/windows.yml`** additions:

```yaml
# Domain join settings
domain_join:         true
domain_name:         "poseidon.local"
domain_ou:           "OU=Ansible-Managed,DC=poseidon,DC=local"
domain_admin_user:   "poseidon\\svc-ansible-join"   # or domain admin
vault_domain_join_pass: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  <paste encrypted string here>

# DC IPs for DNS configuration
dc_primary_ip:   "192.168.1.10"
dc_secondary_ip: "192.168.1.11"   # remove if only one DC
```

---

## Step 6 — Inventory Configuration

Add the new VM to inventory **before** it's domain joined, using its IP address. After the join and reboot you can optionally switch to FQDN.

**`inventory/hosts.yml`**

```yaml
windows:
  hosts:
    win-server-01:
      ansible_host: 192.168.1.201    # IP — not FQDN yet, DNS won't resolve until joined
  vars:
    ansible_connection: winrm
    ansible_winrm_transport: ntlm    # NTLM works pre-join; switch to kerberos post-join
    ansible_winrm_server_cert_validation: ignore
    ansible_port: 5985
    ansible_user: ansible-svc        # local admin account from base config
    ansible_password: "{{ vault_windows_ansible_pass }}"
    ansible_winrm_operation_timeout_sec: 120
    ansible_winrm_read_timeout_sec: 150
```

> **Post-join note:** After joining, you can optionally change `ansible_winrm_transport` to `kerberos` and use the domain account. For an air-gapped environment, NTLM with the local service account continues to work fine after the join — simpler to maintain.

---

## Step 7 — Domain Join Playbook

**`/opt/repo/playbooks/domain-join.yml`**

```yaml
---
# domain-join.yml
# Joins a Windows Server VM to poseidon.local
#
# Usage:
#   ansible-playbook domain-join.yml -i inventory/hosts.yml \
#     -l win-server-01 --ask-vault-pass
#
# Run AFTER configure-windows-base.yml
# VM must be reachable via WinRM before running this

- name: Join Windows Server to poseidon.local
  hosts: "{{ target | default('windows') }}"
  gather_facts: true

  vars:
    domain_name:       "poseidon.local"
    domain_ou:         "OU=Ansible-Managed,DC=poseidon,DC=local"
    domain_admin_user: "poseidon\\svc-ansible-join"
    domain_admin_pass: "{{ vault_domain_join_pass }}"
    dc_primary_ip:     "192.168.1.10"
    dc_secondary_ip:   ""              # set if you have a second DC

  tasks:

    # ── PRE-FLIGHT CHECKS ────────────────────────────────────────────────────────

    - name: Check current domain membership
      ansible.windows.win_powershell:
        script: |
          $cs = Get-CimInstance Win32_ComputerSystem
          Write-Host "Current domain/workgroup: $($cs.Domain)"
          Write-Host "Part of domain: $($cs.PartOfDomain)"
      register: domain_check

    - name: Show current state
      ansible.builtin.debug:
        msg: "{{ domain_check.output }}"

    - name: Skip if already domain joined
      ansible.builtin.meta: end_host
      when: "'poseidon.local' in (domain_check.output | join(''))"

    # ── DNS CONFIGURATION ─────────────────────────────────────────────────────────

    - name: Set DNS to point at DC (required before domain join)
      ansible.windows.win_dns_client:
        adapter_names: "*"
        ipv4_addresses: >-
          {{
            [dc_primary_ip] +
            ([dc_secondary_ip] if dc_secondary_ip | length > 0 else [])
          }}

    - name: Verify DNS resolves poseidon.local
      ansible.windows.win_powershell:
        script: |
          try {
            $result = Resolve-DnsName poseidon.local -ErrorAction Stop
            Write-Host "DNS OK: poseidon.local resolved to $($result[0].IPAddress)"
          } catch {
            Write-Host "DNS FAILED: $($_.Exception.Message)"
            exit 1
          }
      register: dns_check

    - name: Show DNS result
      ansible.builtin.debug:
        msg: "{{ dns_check.output }}"

    - name: Fail if DNS not resolving
      ansible.builtin.fail:
        msg: "Cannot resolve poseidon.local — check DC IP and network connectivity before proceeding"
      when: dns_check.rc != 0

    # ── TIME SYNC ─────────────────────────────────────────────────────────────────

    - name: Sync time with DC before join (Kerberos requires <5 min skew)
      ansible.windows.win_powershell:
        script: |
          w32tm /config /manualpeerlist:"{{ dc_primary_ip }}" /syncfromflags:manual /reliable:yes /update
          Start-Service W32Time -ErrorAction SilentlyContinue
          w32tm /resync /force
          $timeInfo = w32tm /query /status
          Write-Host $timeInfo

    # ── TEST DC CONNECTIVITY ──────────────────────────────────────────────────────

    - name: Test connectivity to DC on key ports
      ansible.windows.win_powershell:
        script: |
          $ports = @(53, 88, 135, 389, 445)
          $dc    = "{{ dc_primary_ip }}"
          foreach ($port in $ports) {
            $result = Test-NetConnection -ComputerName $dc -Port $port -WarningAction SilentlyContinue
            $status = if ($result.TcpTestSucceeded) { "OPEN" } else { "BLOCKED" }
            Write-Host "DC:$port $status"
          }
      register: port_check

    - name: Show port connectivity
      ansible.builtin.debug:
        msg: "{{ port_check.output }}"

    # ── DOMAIN JOIN ───────────────────────────────────────────────────────────────

    - name: Join domain
      microsoft.ad.membership:
        dns_domain_name:       "{{ domain_name }}"
        domain_admin_user:     "{{ domain_admin_user }}"
        domain_admin_password: "{{ domain_admin_pass }}"
        domain_ou_path:        "{{ domain_ou }}"
        state: domain
      register: join_result

    - name: Show join result
      ansible.builtin.debug:
        msg: "Domain join result — reboot required: {{ join_result.reboot_required }}"

    # ── REBOOT ────────────────────────────────────────────────────────────────────

    - name: Reboot to complete domain join
      ansible.windows.win_reboot:
        reboot_timeout:    300
        post_reboot_delay: 45
        msg: "Rebooting to complete domain join"
      when: join_result.reboot_required

    # ── POST-JOIN VERIFICATION ────────────────────────────────────────────────────

    - name: Verify domain membership after reboot
      ansible.windows.win_powershell:
        script: |
          $cs = Get-CimInstance Win32_ComputerSystem
          if ($cs.PartOfDomain -and $cs.Domain -eq "poseidon.local") {
            Write-Host "SUCCESS: $env:COMPUTERNAME is now a member of $($cs.Domain)"
          } else {
            Write-Host "FAILED: Domain join did not complete. Domain: $($cs.Domain)"
            exit 1
          }
      register: verify_result

    - name: Show verification
      ansible.builtin.debug:
        msg: "{{ verify_result.output }}"

    - name: Add Domain Admins to local Administrators (optional)
      ansible.windows.win_group_membership:
        name: Administrators
        members:
          - "poseidon\\Domain Admins"
        state: present

    - name: Final summary
      ansible.windows.win_powershell:
        script: |
          $cs  = Get-CimInstance Win32_ComputerSystem
          $net = Get-NetIPAddress -AddressFamily IPv4 |
                 Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select -First 1
          $dns = Get-DnsClientServerAddress -AddressFamily IPv4 |
                 Where-Object { $_.ServerAddresses.Count -gt 0 } | Select -First 1
          Write-Host "Hostname:    $env:COMPUTERNAME"
          Write-Host "Domain:      $($cs.Domain)"
          Write-Host "IP:          $($net.IPAddress)"
          Write-Host "DNS servers: $($dns.ServerAddresses -join ', ')"
      register: final_summary

    - name: Show final summary
      ansible.builtin.debug:
        msg: "{{ final_summary.output }}"
```

---

## Step 8 — Post-Join Verification

Run these on the VM or via Ansible to confirm everything is healthy after the join.

### Via Ansible

```bash
# Quick ping to confirm WinRM still works post-reboot
ansible win-server-01 -i inventory/hosts.yml -m ansible.windows.win_ping --ask-vault-pass

# Confirm domain membership
ansible win-server-01 -i inventory/hosts.yml \
  -m ansible.windows.win_powershell \
  -a "script=(Get-CimInstance Win32_ComputerSystem).Domain" \
  --ask-vault-pass
```

### On the VM directly

```powershell
# Confirm domain
(Get-CimInstance Win32_ComputerSystem).Domain
# Expected: poseidon.local

# Confirm computer account exists in AD (run from DC or domain member)
Get-ADComputer win-server-01 | Select Name, DistinguishedName, Enabled

# Confirm DNS registered
Resolve-DnsName win-server-01.poseidon.local

# Confirm Kerberos working
klist
```

---

## Troubleshooting

### "The RPC server is unavailable" or WinRM connection failure after reboot

WinRM sometimes takes 30–60 seconds to come back after a domain join reboot. The playbook uses `post_reboot_delay: 45` to account for this. If you still get failures, increase it to 90.

```yaml
ansible.windows.win_reboot:
  post_reboot_delay: 90
```

### "DNS name does not exist" during join

The VM's DNS is not pointing at the DC. Verify:

```powershell
# On the VM
Get-DnsClientServerAddress -AddressFamily IPv4
# Should show DC IP, not a DHCP-assigned external DNS

# Test manually
nslookup poseidon.local
# Should resolve — if it doesn't, the DNS config step failed
```

Fix: run just the DNS task manually:
```bash
ansible win-server-01 -i inventory/hosts.yml \
  -m ansible.windows.win_dns_client \
  -a "adapter_names=* ipv4_addresses=192.168.1.10" \
  --ask-vault-pass
```

### "The credentials supplied conflict with an existing set of credentials" (NTLM error)

Usually means the local account password in inventory doesn't match what's on the VM. Verify:

```bash
# Test WinRM manually from autoserver
ansible win-server-01 -i inventory/hosts.yml -m ansible.windows.win_ping --ask-vault-pass
```

### "Logon failure: the user has not been granted the requested logon type"

The domain join account doesn't have permission to join computers to the target OU. Either:
- Use a full domain admin account temporarily
- Re-delegate OU permissions (see Step 4)

### "Maximum computer accounts" error

By default, non-admin users can only join 10 computers to a domain (ms-DS-MachineAccountQuota). Fix:

```powershell
# Run on DC — increase limit or set to unlimited (-1)
Set-ADDomain -Identity poseidon.local -Replace @{"ms-DS-MachineAccountQuota"="0"}
# 0 = only admins can join; use delegation instead (Step 4, Option B)
```

Or better — grant the service account explicit rights via `dsacls` as shown in Step 4.

### Kerberos clock skew error during join

```
KDC_ERR_SKEWTIME or "There is a time and/or date difference between the client and server"
```

Fix:
```powershell
# Force time sync before running domain join playbook
w32tm /resync /force

# Check offset
w32tm /query /status
# "Offset" should be under 5 minutes
```

---

## Full Pipeline — Deploy + Join

Once all the above is configured, this is the full workflow to go from nothing to a domain-joined Windows Server:

```bash
# Step 1 — Deploy VM from OVA
ansible-playbook deploy-from-ova.yml \
  -e "vm_name=win-server-01 \
      ova_file=windows/windows-server-2022.ova \
      datastore=datastore1 \
      network=VM-Network" \
  --ask-vault-pass

# Step 2 — Base configuration (hostname, WinRM, local accounts, firewall)
ansible-playbook configure-windows-base.yml \
  -i inventory/hosts.yml -l win-server-01 \
  --ask-vault-pass

# Step 3 — Domain join
ansible-playbook domain-join.yml \
  -i inventory/hosts.yml -l win-server-01 \
  --ask-vault-pass

# Step 4 — Verify
ansible win-server-01 -i inventory/hosts.yml \
  -m ansible.windows.win_ping \
  --ask-vault-pass
```

Or chain them into a single master playbook:

**`/opt/repo/playbooks/provision-windows.yml`**

```yaml
---
# Full Windows Server provisioning pipeline
# Deploy from OVA → base config → domain join
#
# Usage:
#   ansible-playbook provision-windows.yml \
#     -e "vm_name=win-server-01 ova_file=windows/windows-server-2022.ova \
#         datastore=datastore1 network=VM-Network" \
#     --ask-vault-pass

- import_playbook: deploy-from-ova.yml
- import_playbook: configure-windows-base.yml
- import_playbook: domain-join.yml
```

---

## Notes for Air-Gapped Environments

- The `microsoft.ad` collection must be downloaded and staged in `/opt/repo/collections/` before crossing the air gap (handled by `bootstrap.sh`)
- After domain join, Windows will attempt to contact Microsoft for Windows Update — this is blocked by the disabled `wuauserv` service from the base config playbook
- Group Policy will apply on next boot/login after the join — make sure your GPOs don't break WinRM or the ansible-svc local account
- If your domain has a WSUS server on the closed network, you can re-enable `wuauserv` and point it there via GPO

---

*Last updated: May 2026*
*Maintainer: Wisebird Holdings LLC / FalconRock Consulting*
*Domain: poseidon.local*
