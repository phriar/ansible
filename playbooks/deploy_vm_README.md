# deploy_vm.yml

Deploys a virtual machine from a vCenter template onto an ESXi host. On first boot, VMware guest customization applies the hostname and static IP inside the guest OS — no post-boot SSH required for the rename/IP steps.

Supports both Linux and Windows guest types.

---

## Prerequisites

| Requirement | Details |
|---|---|
| `community.vmware` collection | Run `ansible-galaxy collection install -r requirements.yml` |
| VMware Tools in the template | Linux: `open-vm-tools` **and** `perl` must be installed. Windows: sysprep must be available |
| `vault_vcenter_password` | Set in `group_vars/all/vault.yml` and encrypted with `ansible-vault` |
| vCenter or standalone ESXi | Tested against vCenter 7+; works on standalone ESXi with `vcenter_cluster` left blank |

---

## Files

| File | Purpose |
|---|---|
| `playbooks/deploy_vm.yml` | The playbook — do not edit connection logic here |
| `playbooks/vars/deploy_vm.yml` | All tuneable variables — edit this before running |
| `group_vars/all/vault.yml` | Encrypted secrets: `vault_vcenter_password`, `vault_vm_admin_password` |

---

## Quick start

### 1. Set your variables

Edit `playbooks/vars/deploy_vm.yml` — minimum required changes:

```yaml
vcenter_hostname: vcenter.example.com
vcenter_esxi_host: esxi01.example.com
vcenter_datacenter: Datacenter
vcenter_datastore: datastore01
vm_template: ubuntu2404-template
vm_name: new-server-01
vm_ip: 10.0.1.50
vm_netmask: 255.255.255.0
vm_gateway: 10.0.1.1
```

### 2. Set the vCenter password in the vault

```bash
ansible-vault edit group_vars/all/vault.yml
# set vault_vcenter_password: "your_real_password"
```

### 3. Run

```bash
ansible-playbook playbooks/deploy_vm.yml --ask-vault-pass
```

---

## Variable reference

### vCenter connection

| Variable | Default | Description |
|---|---|---|
| `vcenter_hostname` | `vcenter.example.com` | vCenter FQDN or IP |
| `vcenter_username` | `administrator@vsphere.local` | vCenter login |
| `vcenter_password` | from vault | Set via `vault_vcenter_password` in vault.yml |
| `vcenter_datacenter` | `Datacenter` | Datacenter name in vCenter |
| `vcenter_cluster` | `Cluster01` | Cluster name — omit for standalone ESXi |
| `vcenter_esxi_host` | `esxi01.example.com` | Target ESXi host to place the VM on |
| `vcenter_datastore` | `datastore01` | Datastore for VM disk files |
| `vcenter_folder` | `/Datacenter/vm` | vCenter inventory folder for the new VM |

### VM identity

| Variable | Default | Description |
|---|---|---|
| `vm_template` | `ubuntu2404-template` | Name of the source template in vCenter |
| `vm_name` | `new-server-01` | vCenter display name **and** guest OS hostname |
| `vm_domain` | `example.com` | DNS domain — appended to hostname inside the guest |

### VM hardware

| Variable | Default | Description |
|---|---|---|
| `vm_num_cpus` | `2` | vCPU count |
| `vm_memory_mb` | `4096` | RAM in MB |
| `vm_disk_gb` | `50` | Disk size in GB. Set to `0` to keep the template's disk size unchanged |

### Networking

| Variable | Default | Description |
|---|---|---|
| `vm_network_label` | `VM Network` | Port group name in vCenter |
| `vm_ip` | `10.0.1.50` | Static IP to assign |
| `vm_netmask` | `255.255.255.0` | Subnet mask |
| `vm_gateway` | `10.0.1.1` | Default gateway |
| `vm_dns_servers` | `[1.1.1.1, 8.8.8.8]` | List of DNS servers |

### Guest OS customization

| Variable | Default | Description |
|---|---|---|
| `vm_is_windows` | `false` | Set to `true` for Windows guests |
| `vm_timezone` | `UTC` | Linux: Olson tz string (e.g. `America/New_York`). Windows: numeric index |
| `vault_vm_admin_password` | — | Windows only: local Administrator password, set in vault |

---

## Overriding variables on the CLI

Any variable can be overridden at run time with `-e`. Useful for deploying multiple VMs without editing the vars file:

```bash
ansible-playbook playbooks/deploy_vm.yml \
  -e vm_name=db01 \
  -e vm_ip=10.0.2.20 \
  -e vm_memory_mb=8192 \
  --ask-vault-pass
```

Or pass an entire alternate vars file:

```bash
ansible-playbook playbooks/deploy_vm.yml \
  -e @my_custom_vars.yml \
  --ask-vault-pass
```

---

## How it works

```
localhost
    │
    ├─ 1. Assert required vars are set
    ├─ 2. Confirm template exists in vCenter
    ├─ 3. Clone template → new VM
    │       ├─ Apply hardware overrides (CPU, RAM, disk)
    │       └─ Attach customization spec (hostname, IP, DNS, domain)
    │               └─ VMware Tools applies this on first boot inside the guest
    ├─ 4. Wait for VMware Tools to report guest is up (up to 5 min)
    ├─ 5. Wait for SSH port 22 (Linux) or WinRM port 5985 (Windows)
    └─ 6. Print deployment summary
```

The hostname rename and static IP are applied by VMware's guest customization engine **inside** the guest OS on first boot — the same mechanism as a vCenter customization specification. No Ansible connection to the guest is needed for this step.

---

## Troubleshooting

**Customization silently fails / hostname not set**
The template is missing `perl`. On Ubuntu/Debian: `apt install open-vm-tools perl`. On RHEL/Rocky: `dnf install open-vm-tools perl`.

**Task hangs at "Wait for VMware Tools"**
VMware Tools is not installed or not running in the template. Install `open-vm-tools` and ensure the service starts on boot.

**`vmware_guest` fails with certificate error**
Set `validate_certs: true` and trust your vCenter CA, or keep `validate_certs: false` for lab environments.

**Deploying to standalone ESXi (no vCenter cluster)**
Leave `vcenter_cluster` blank or remove it — `vcenter_esxi_host` alone is sufficient.

**IP not applied / VM gets DHCP instead**
Guest customization requires the guest to be cleanly shut down before cloning. Power off the template VM and ensure no snapshot is pending.
