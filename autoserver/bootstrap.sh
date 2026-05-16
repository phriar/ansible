#!/bin/bash
# Run as root on an internet-connected Ubuntu 22.04 VM before OVA export.
# No pre-setup required — this script creates all directories itself.
#
# Usage:
#   sudo bash bootstrap.sh
set -e

# ── Create full directory tree first ─────────────────────────────────────────
echo "=== Creating directory structure ==="
mkdir -p /opt/repo/{ova/{windows,rhel,vendor},iso,pip-cache,collections,apt-cache}
mkdir -p /opt/repo/playbooks/{inventory,group_vars,templates,roles}

# ── System packages ───────────────────────────────────────────────────────────
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

# ── Python dependencies ───────────────────────────────────────────────────────
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

# ── Ansible collections ───────────────────────────────────────────────────────
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

# ── Cache apt packages ────────────────────────────────────────────────────────
echo "=== Caching apt packages for offline use ==="
apt-get install -y --download-only \
  ansible python3-pip nginx nfs-kernel-server \
  -o Dir::Cache::archives=/opt/repo/apt-cache

# ── nginx — serves /opt/repo over HTTP so ESXi can pull OVAs ─────────────────
echo "=== Configuring nginx ==="
cat > /etc/nginx/sites-available/repo << 'NGINXEOF'
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
NGINXEOF

ln -sf /etc/nginx/sites-available/repo /etc/nginx/sites-enabled/repo
rm -f /etc/nginx/sites-enabled/default
systemctl enable nginx
systemctl restart nginx

# ── Ansible config ────────────────────────────────────────────────────────────
echo "=== Writing ansible.cfg ==="
cat > /etc/ansible/ansible.cfg << 'CFGEOF'
[defaults]
inventory           = /opt/repo/playbooks/autoserver/inventory
collections_path    = ~/.ansible/collections:/opt/repo/collections
roles_path          = /opt/repo/playbooks/autoserver/roles
host_key_checking   = False
retry_files_enabled = False
stdout_callback     = yaml
interpreter_python  = auto_silent

[ssh_connection]
pipelining          = True
ssh_args            = -o ControlMaster=auto -o ControlPersist=60s
CFGEOF

# ── Permissions ───────────────────────────────────────────────────────────────
echo "=== Setting permissions ==="
chmod -R 755 /opt/repo
chown -R www-data:www-data /opt/repo/ova /opt/repo/iso

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== Bootstrap complete ==="
echo "Next steps:"
echo "  1. Copy OVAs to /opt/repo/ova/  (windows/, rhel/, vendor/)"
echo "  2. Copy ISOs to /opt/repo/iso/"
echo "  3. Verify nginx:  curl http://localhost/ova/"
echo "  4. Copy playbooks from this repo to /opt/repo/playbooks/"
echo "  5. Snapshot this VM, then export as OVA."
