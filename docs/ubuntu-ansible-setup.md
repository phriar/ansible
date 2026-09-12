# Ubuntu VM Setup — Autoserver / Ansible Control Node

This guide walks through building the autoserver from scratch: create the Ubuntu VM in vSphere/ESXi, do initial OS config, install Ansible and cache everything needed for offline use, then connect to it from VSCode and pull down this repo.

See `docs/autoserver-design.md` for the full design rationale and pre-export checklist — this doc is the hands-on build runbook.

---

## Table of contents

1. [Create the Ubuntu VM](#1-create-the-ubuntu-vm)
2. [Initial Ubuntu configuration](#2-initial-ubuntu-configuration)
3. [Configure SSH for remote access](#3-configure-ssh-for-remote-access)
4. [Clone the repo and run bootstrap.sh](#4-clone-the-repo-and-run-bootstrapsh)
5. [Connect VSCode via Remote SSH](#5-connect-vscode-via-remote-ssh)
6. [Verify everything works](#6-verify-everything-works)

---

## 1. Create the Ubuntu VM

### Spec

| Setting | Value |
|---|---|
| OS | **Ubuntu Server 22.04 LTS** (not 24.04 — matches the design doc's pyVmomi/collections compatibility target) |
| vCPU | 4 |
| RAM | 8 GB |
| Disk | 1 TB thin provisioned — this box caches every OVA, ISO, collection, and package it will ever need offline |
| NIC | VMXNET3, on the management network that can reach ESXi/vCenter and every VM you'll deploy |

Download the ISO from [releases.ubuntu.com/22.04](https://releases.ubuntu.com/22.04/) (server ISO, not desktop).

### Build it in vSphere/ESXi (your environment)

1. Upload the Ubuntu 22.04 Server ISO to a datastore: **Storage → Datastore → Datastore browser → Upload** (or via vCenter's Content Library).
2. **Actions → New Virtual Machine** (or **Create/Register VM** on standalone ESXi).
3. Guest OS family: **Linux**, version: **Ubuntu Linux (64-bit)**.
4. Storage: select a datastore with 1 TB+ free.
5. Customize hardware:
   - CPU: 4, Memory: 8192 MB
   - New Hard Disk: 1024 GB, **Thin provision**
   - New Network: your management port group, adapter type **VMXNET3**
   - New CD/DVD Drive: **Datastore ISO file** → browse to the ISO you uploaded → check **Connect at power on**
6. Finish, then power on and open the console.

> If you were planning to start from an existing RHEL template on this environment — skip it. It may be stale/staged with drift you don't control, and the autoserver needs to be Ubuntu anyway (bootstrap.sh, nginx, and the vmware collections are all built around it). A clean ISO install gives you a known-good baseline you can document from bit one — which matters since this whole build has to be reproducible on the air-gapped side.

---

## 2. Initial Ubuntu configuration

### Ubuntu Server installer walkthrough

| Prompt | Recommended choice |
|---|---|
| Language | English |
| Keyboard | Match your layout |
| Installation type | Ubuntu Server (not minimized) |
| Network | Set a **static IP** now if you know the address — saves a step later. Otherwise note the DHCP address assigned. |
| Storage | Use entire disk, set up as LVM |
| Profile | Set your name, server name (`autoserver`), username, and a strong password |
| SSH | **Check "Install OpenSSH server"** — essential for remote access |
| Featured snaps | Skip all |

Reboot and remove the ISO from the CD/DVD device when prompted (**Edit Settings → CD/DVD → Disconnect**, or it'll just be ignored on next boot since it's not marked as the boot device).

### Log in and update the system

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

### Confirm the IP address

```bash
ip addr show
```

If you didn't set a static IP during install, set one now (via netplan) or reserve a DHCP lease — this address is going in `autoserver/inventory/group_vars/all/vars.yml` as `repo_base_url`, so it needs to stay put.

---

## 3. Configure SSH for remote access

Do this from **your local machine** (the one running VSCode).

```bash
# Skip if you already have a key at ~/.ssh/id_ed25519
ssh-keygen -t ed25519 -C "autoserver" -f ~/.ssh/id_ed25519

# Copy it to the VM
ssh-copy-id -i ~/.ssh/id_ed25519.pub your_username@AUTOSERVER_IP

# Test passwordless login
ssh your_username@AUTOSERVER_IP
exit
```

Add a host alias — edit `~/.ssh/config` on your local machine:

```
Host autoserver
    HostName AUTOSERVER_IP
    User your_username
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
```

Now `ssh autoserver` works from anywhere.

---

## 4. Clone the repo and run bootstrap.sh

`bootstrap.sh` is the actual install step — it installs Ansible, the Galaxy collections, and every Python/apt dependency this project needs, **and** caches all of it under `/opt/repo/` so the same box can be re-provisioned with zero internet access later. Don't hand-install Ansible separately; run the script.

```bash
ssh autoserver

# Git is the only thing you need before the repo exists
sudo apt install -y git
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# Clone the repo (HTTPS — you'll be prompted for a GitHub PAT, not your password)
git clone https://github.com/phriar/ansible.git
cd ansible

# Run the bootstrap — installs Ansible, collections, nginx, and caches
# everything to /opt/repo for offline reuse
sudo bash autoserver/bootstrap.sh
```

What this gets you, all in one pass:

| Cached to | Contents |
|---|---|
| `/opt/repo/apt-cache/` | `.deb`s for ansible, nginx, nfs-kernel-server, python3-pip |
| `/opt/repo/pip-cache/` | wheels for pyVmomi, pywinrm, requests, requests-ntlm/kerberos/credssp |
| `/opt/repo/collections/` | `.tar.gz` of every Galaxy collection in `requirements.yml` |
| `/opt/repo/ova/`, `/opt/repo/iso/` | empty — you stage your OVAs/ISOs here manually |
| nginx | serving `/opt/repo` at `http://autoserver/` |

> **This is what eventually goes on the offline-replication ISO.** When you're ready to burn one, everything under `/opt/repo/{apt-cache,pip-cache,collections}` plus the git repo itself is what you stage. Note: this only covers the autoserver's own (Ubuntu/apt) dependencies — it does **not** set up an offline RPM/dnf mirror for the RHEL/Rocky target VMs `configure-rhel.yml` will manage. If those targets need packages this environment doesn't already provide via their own repos, that's a separate `reposync`/`createrepo` mirror to build later — flagging it now so it doesn't surprise you air-gapped.

### SSH key for git operations from the autoserver itself

If you'll `git push` changes from the autoserver (rather than only editing via VSCode Remote-SSH, which uses your local machine's git credentials over the same SSH tunnel), set up a deploy key:

```bash
ssh-keygen -t ed25519 -C "autoserver" -f ~/.ssh/github_ed25519
cat ~/.ssh/github_ed25519.pub
# Paste into GitHub → Settings → SSH and GPG keys → New SSH key
```

---

## 5. Connect VSCode via Remote SSH

1. Install the **Remote - SSH** extension (Microsoft) in VSCode.
2. `Ctrl+Shift+P` → `Remote-SSH: Connect to Host` → select `autoserver`.
3. Select **Linux** when prompted for platform.
4. Once connected (bottom-left shows `>< SSH: autoserver`), **Open Folder** → `/home/your_username/ansible`.
5. Install these extensions **on the remote**: **YAML** (Red Hat), **Ansible** (Red Hat), **GitLens** (GitKraken).

---

## 6. Verify everything works

Run from inside the repo on the autoserver:

```bash
# Confirm ansible.cfg is picked up
ansible --version | grep "config file"

# Confirm the autoserver inventory parses
ansible-inventory -i autoserver/inventory/hosts.yml --list

# Smoke test
ansible localhost -m ansible.builtin.ping

# Confirm collections from requirements.yml are present
ansible-galaxy collection list | grep -E "vmware|windows|posix|general|microsoft.ad"

# nginx is serving the repo
curl http://localhost/ova/
```

---

## Summary

| What | Where |
|---|---|
| Autoserver IP | Set in step 2 — keep it static |
| SSH config (local machine) | `~/.ssh/config` |
| Repo location (autoserver) | `~/ansible/` |
| Vault password | `~/.vault_pass` on the autoserver, `chmod 600` — never commit it |
| vCenter/ESXi/domain credentials | `autoserver/inventory/group_vars/all/vault.yml` — **must be `ansible-vault encrypt`ed before you commit it** |

### Vault shortcut

```bash
echo "your_vault_password" > ~/.vault_pass
chmod 600 ~/.vault_pass
```

Add to `ansible.cfg`:

```ini
[defaults]
vault_password_file = ~/.vault_pass
```

### Next: writing/validating the deploy playbooks

Once this is done, you're at the point where you edit `autoserver/inventory/group_vars/all/vault.yml` with real vCenter credentials and start working through `autoserver/deploy-vcenter.yml` / `autoserver/deploy-vm-template.yml` against your actual environment. See `docs/bringup-plan.md` for the day-by-day plan.
