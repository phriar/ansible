# Ubuntu VM Setup — Ansible Control Node

This guide walks through spinning up an Ubuntu VM, installing Ansible, configuring it as a remote development machine, connecting to it from VSCode, and pulling down this repository.

---

## Table of contents

1. [Create the Ubuntu VM](#1-create-the-ubuntu-vm)
2. [Initial Ubuntu configuration](#2-initial-ubuntu-configuration)
3. [Install Ansible](#3-install-ansible)
4. [Configure SSH for remote access](#4-configure-ssh-for-remote-access)
5. [Connect VSCode via Remote SSH](#5-connect-vscode-via-remote-ssh)
6. [Pull down the Ansible repo from GitHub](#6-pull-down-the-ansible-repo-from-github)
7. [Verify everything works](#7-verify-everything-works)

---

## 1. Create the Ubuntu VM

### Download Ubuntu Server

Download the latest Ubuntu Server LTS ISO from [ubuntu.com/download/server](https://ubuntu.com/download/server).  
Recommended: **Ubuntu Server 24.04 LTS** (Noble Numbat).

### VMware Workstation / Fusion

1. Open VMware → **File → New Virtual Machine**
2. Select **Typical (recommended)** → Next
3. Choose **Installer disc image file (ISO)** → browse to your downloaded `.iso` → Next
4. Set a VM name (e.g. `ansible-control`) and note the location → Next
5. Set disk size — **40 GB minimum**, Store as single file → Next
6. Click **Customize Hardware**:
   - Memory: **4 GB** minimum
   - Processors: **2 cores**
   - Network Adapter: **Bridged** (so the VM gets its own IP on your network)
7. Click **Finish** — the VM will boot into the Ubuntu installer

### VirtualBox

1. Open VirtualBox → **New**
2. Name: `ansible-control`, Type: `Linux`, Version: `Ubuntu (64-bit)` → Next
3. Memory: **4096 MB** → Next
4. Hard disk → **Create a virtual hard disk now**, VDI, Dynamically allocated, **40 GB** → Create
5. Select the VM → **Settings → Storage** → click the empty optical drive → attach your ISO
6. **Settings → Network → Adapter 1** → Attached to: **Bridged Adapter** → choose your physical NIC
7. Start the VM

### Hyper-V (Windows)

1. Open Hyper-V Manager → **New → Virtual Machine**
2. Name: `ansible-control` → Next
3. Generation: **Generation 2** → Next
4. Startup memory: **4096 MB**, uncheck Dynamic Memory → Next
5. Connection: your network switch → Next
6. Create a virtual hard disk, **40 GB** → Next
7. Install OS from ISO → browse to your `.iso` → Finish
8. **Settings → Security** → uncheck **Secure Boot** (required for Ubuntu ISO to boot)
9. Start the VM

---

## 2. Initial Ubuntu configuration

### Ubuntu Server installer walkthrough

Work through the installer prompts:

| Prompt | Recommended choice |
|---|---|
| Language | English |
| Keyboard | Match your layout |
| Installation type | Ubuntu Server (not minimized) |
| Network | Note the IP assigned — you'll need it later |
| Storage | Use entire disk, set up as LVM |
| Profile | Set your name, server name (`ansible-control`), username, and a strong password |
| SSH | **Check "Install OpenSSH server"** — essential for remote access |
| Featured snaps | Skip all |

The install will take a few minutes. When it completes, select **Reboot Now** and remove the ISO when prompted.

### Log in and update the system

Log in with the username and password you set during install, then run:

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

### Find the VM's IP address

After reboot, log back in and run:

```bash
ip addr show
```

Look for the `inet` address on your main network interface (usually `ens32`, `ens33`, or `eth0`). Note this IP — you'll use it throughout.

```
# Example output
2: ens33: <BROADCAST,MULTICAST,UP,LOWER_UP>
    inet 192.168.1.105/24  ← this is your VM's IP
```

> **Tip:** assign the VM a static IP or a DHCP reservation on your router so the address doesn't change between reboots.

---

## 3. Install Ansible

### Add the Ansible PPA and install

```bash
sudo apt install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install -y ansible
```

### Verify the installation

```bash
ansible --version
```

Expected output (version numbers will vary):

```
ansible [core 2.17.x]
  config file = /etc/ansible/ansible.cfg
  python version = 3.12.x
  ...
```

### Install pip and Python dependencies

Some Ansible modules (including the VMware collection) require additional Python packages:

```bash
sudo apt install -y python3-pip python3-venv
pip3 install --user pyVmomi requests
```

### Install required Ansible collections

Once you've cloned the repo (step 6), run this from the repo root. For now, install the VMware collection manually:

```bash
ansible-galaxy collection install community.vmware community.general ansible.posix
```

---

## 4. Configure SSH for remote access

VSCode Remote SSH connects via SSH key authentication. Follow these steps on **your local machine** (the machine running VSCode), then copy the key to the VM.

### Generate an SSH key pair (local machine)

> Skip this if you already have an SSH key at `~/.ssh/id_ed25519`.

```bash
ssh-keygen -t ed25519 -C "ansible-control" -f ~/.ssh/id_ed25519
```

Press Enter twice to accept the default file location and an empty passphrase (or set one for extra security).

### Copy your public key to the VM

Replace `YOUR_VM_IP` with the IP you noted in step 2:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub your_username@YOUR_VM_IP
```

Enter your VM password when prompted. This adds your public key to `~/.ssh/authorized_keys` on the VM.

### Test passwordless SSH

```bash
ssh your_username@YOUR_VM_IP
```

You should connect without being asked for a password. If it works, exit the VM:

```bash
exit
```

### Add a host alias (optional but recommended)

On your **local machine**, edit `~/.ssh/config` (create it if it doesn't exist):

```
Host ansible-control
    HostName YOUR_VM_IP
    User your_username
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
```

After saving this, you can connect with just:

```bash
ssh ansible-control
```

---

## 5. Connect VSCode via Remote SSH

### Install the Remote SSH extension

1. Open VSCode
2. Press `Ctrl+Shift+X` (or `Cmd+Shift+X` on Mac) to open Extensions
3. Search for **Remote - SSH** (published by Microsoft)
4. Click **Install**

### Connect to the VM

1. Press `F1` (or `Ctrl+Shift+P`) to open the command palette
2. Type `Remote-SSH: Connect to Host` and select it
3. Select `ansible-control` from the list (populated from your `~/.ssh/config`), or type `your_username@YOUR_VM_IP`
4. VSCode will open a new window and install the VSCode server on the VM automatically — this takes about 30 seconds on first connection
5. When prompted, select **Linux** as the platform and click **Continue**

You'll know it's connected when the bottom-left corner of VSCode shows:

```
>< SSH: ansible-control
```

### Install recommended extensions on the remote

Once connected, install these extensions **on the remote host** (VSCode will prompt you, or install manually via the Extensions panel):

| Extension | Publisher | Purpose |
|---|---|---|
| YAML | Red Hat | Syntax highlighting and validation for `.yml` files |
| Ansible | Red Hat | Playbook linting, autocomplete, module docs |
| GitLens | GitKraken | Enhanced git history and blame |

---

## 6. Pull down the Ansible repo from GitHub

### Install Git (if not already installed)

```bash
sudo apt install -y git
git --version
```

### Configure Git identity

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

### Option A — HTTPS (simpler, prompts for credentials)

```bash
cd ~
git clone https://github.com/phriar/ansible.git
cd ansible
```

If prompted for credentials, use your GitHub username and a **Personal Access Token** (not your password). Generate one at GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens. Give it **Contents: Read and Write** on this repo.

To avoid entering credentials every time:

```bash
git config --global credential.helper store
# The next git pull/push will prompt once and then save the token
```

### Option B — SSH (no token prompts after setup)

Generate an SSH key **on the VM** and add it to GitHub:

```bash
# On the VM
ssh-keygen -t ed25519 -C "ansible-control-vm" -f ~/.ssh/github_ed25519
cat ~/.ssh/github_ed25519.pub
```

Copy the output, then go to **GitHub → Settings → SSH and GPG keys → New SSH key**, paste it in, and save.

Add this to `~/.ssh/config` on the VM:

```
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_ed25519
```

Test the connection:

```bash
ssh -T git@github.com
# Expected: Hi phriar! You've successfully authenticated...
```

Then clone using the SSH URL:

```bash
cd ~
git clone git@github.com:phriar/ansible.git
cd ansible
```

### Open the repo in VSCode

Back in your VSCode window (connected via Remote SSH):

1. Press `Ctrl+Shift+E` to open the Explorer panel
2. Click **Open Folder**
3. Navigate to `/home/your_username/ansible` → click **OK**

VSCode is now editing files directly on the VM's filesystem over SSH.

---

## 7. Verify everything works

Run these checks from inside the repo directory on the VM:

```bash
# Confirm Ansible sees the config file
ansible --version | grep "config file"
# Expected: config file = /home/your_username/ansible/ansible.cfg

# Confirm inventory parses cleanly
ansible-inventory -i inventories/staging/hosts.ini --list

# Ping localhost as a smoke test
ansible localhost -m ansible.builtin.ping
# Expected: localhost | SUCCESS => {"ping": "pong"}

# Install Galaxy collections from requirements.yml
ansible-galaxy collection install -r requirements.yml
```

---

## Summary

| What | Where |
|---|---|
| VM IP | Noted in step 2 — consider a static DHCP lease |
| SSH config (local) | `~/.ssh/config` on your local machine |
| Repo location (VM) | `~/ansible/` |
| Vault password | Store in `~/.vault_pass` on the VM, `chmod 600 ~/.vault_pass` |
| vCenter credentials | `group_vars/all/vault.yml` — encrypt before committing |

### Vault shortcut

To avoid typing `--ask-vault-pass` every run, create a password file on the VM:

```bash
echo "your_vault_password" > ~/.vault_pass
chmod 600 ~/.vault_pass
```

Then add to `ansible.cfg`:

```ini
[defaults]
vault_password_file = ~/.vault_pass
```

> Never commit `~/.vault_pass` — it lives only on the VM and is already covered by `.gitignore`.
