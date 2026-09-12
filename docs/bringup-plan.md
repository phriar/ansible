# Autoserver Bring-Up Plan — 6 Days

A day-by-day plan for standing up the autoserver against a real vCenter environment and getting the first template-clone-and-configure loop working, at 3–5 hrs/day.

**Context worth knowing before you start:** most of the playbooks this plan uses already exist in this repo — `deploy-esxi.yml`, `deploy-vcenter.yml`, `deploy-vm-template.yml`, `configure-rhel.yml`, `configure-windows.yml`, plus the `rename`/`network`/`domain_join` roles. This week is mostly about *building the real box* and *validating those playbooks against your actual vCenter*, not writing everything from a blank file. Where a day says "write," read it as "adapt and test" unless noted otherwise.

---

## Day 1 — Build the autoserver VM (manual)

Follow `docs/ubuntu-ansible-setup.md` sections 1–3.

- [ ] Upload Ubuntu 22.04 Server ISO to a datastore
- [ ] Create the VM in vSphere/ESXi (4 vCPU / 8 GB / 1 TB thin / VMXNET3) — skip the stale RHEL template, install fresh
- [ ] Run the installer, set a static IP, enable OpenSSH
- [ ] `apt update && apt upgrade`, reboot
- [ ] Generate/copy your SSH key, confirm passwordless `ssh autoserver` from your workstation
- [ ] Add the `autoserver` alias to `~/.ssh/config`

**Done when:** you can `ssh autoserver` from your workstation without a password prompt.

---

## Day 2 — Install Ansible, cache for offline, connect VSCode

Follow `docs/ubuntu-ansible-setup.md` sections 4–6.

- [ ] `apt install git`, clone this repo onto the autoserver
- [ ] Run `sudo bash autoserver/bootstrap.sh` — installs Ansible/collections/nginx and caches debs, pip wheels, and collections under `/opt/repo/`
- [ ] Confirm `ansible --version`, `ansible-galaxy collection list`, `curl http://localhost/ova/`
- [ ] Connect VSCode Remote-SSH to `autoserver`, open the repo folder, install the YAML/Ansible/GitLens extensions on the remote
- [ ] Set up `~/.vault_pass` and `vault_password_file` in `ansible.cfg` so you're not typing `--ask-vault-pass` all week

**Done when:** you can edit files on the autoserver from your local VSCode, and `ansible localhost -m ansible.builtin.ping` succeeds from the repo root.

---

## Day 3 — vCenter connectivity

This is the first day touching your real vCenter, so budget time for credential/permissions back-and-forth.

- [ ] Get a vCenter service account (or your own creds) with rights to deploy/clone/power VMs in the target folder
- [ ] `ansible-vault edit autoserver/inventory/group_vars/all/vault.yml` — set `vault_vcenter_password` (and `vault_esxi_password` if you'll also test standalone ESXi). Encrypt the file if it isn't already (`ansible-vault encrypt ...`) — **do not commit it in plaintext**
- [ ] Update `autoserver/inventory/group_vars/all/vars.yml`: `vcenter_host`, `vcenter_user`, `vcenter_datacenter`, `vcenter_cluster`, `vcenter_folder` to match your environment
- [ ] Sanity-check auth without touching any VM — e.g. `community.vmware.vcenter_about_info` or `community.vmware.vmware_vm_info` in an ad-hoc play
- [ ] Find the real name of the template you'll clone from (or confirm one exists / needs to be built) — you'll need this for `vm_template` in `autoserver/vars/deploy-vm-template.yml`

**Done when:** an ad-hoc Ansible task against vCenter authenticates and returns real inventory data (cluster/datastore/template names) — no VM changes yet.

---

## Day 4 — Deploy a VM from the template

Now exercise `autoserver/deploy-vm-template.yml` for real.

- [ ] Fill in `autoserver/vars/deploy-vm-template.yml`: `vm_template`, `vcenter_datastore`, `vcenter_esxi_host`/`vcenter_cluster`, `vm_network_label`, `vm_ip`/`vm_netmask`/`vm_gateway`/`vm_dns_servers`
- [ ] Confirm the template has `open-vm-tools` + `perl` (Linux) so guest customization works — see `docs/deploy-vm-template.md` if it's missing
- [ ] Dry run: `ansible-playbook autoserver/deploy-vm-template.yml --check --diff`
- [ ] Real run: `ansible-playbook autoserver/deploy-vm-template.yml -e vm_name=<name> -e vm_ip=<ip>`
- [ ] Add the new VM to `autoserver/inventory/hosts.yml` under the right group (`rhel`/`windows`)
- [ ] Confirm SSH (or WinRM) into the freshly cloned VM

**Done when:** a VM cloned from the template boots with the hostname/IP you specified and you can log into it.

---

## Day 5 — Post-deploy configuration

Exercise `configure-rhel.yml` (or `configure-windows.yml`) against the VM from Day 4.

- [ ] `ansible-playbook autoserver/configure-rhel.yml -l <vm_name> --ask-vault-pass` (or your vault-password-file)
- [ ] Verify each role independently if something fails: `--tags rename`, `--tags network`, `--tags domain` (domain join is off by default — `-e domain_join_enabled=true` to test it, see `docs/windows-domain-join.md`)
- [ ] Fix whatever breaks against your real environment — DNS, gateway reachability, sudo/WinRM auth, AD join permissions are the usual suspects
- [ ] Re-run `ansible rhel -m ansible.builtin.ping` (or `win_ping`) to confirm idempotency — running it twice shouldn't change anything the second time

**Done when:** `deploy-vm-template.yml` → `configure-rhel.yml` is a clean, repeatable, two-command loop from template to configured VM.

---

## Day 6 — Buffer, offline validation, and write down what changed

- [ ] Catch-up day for whatever slipped from Days 3–5 (vCenter permission issues eat time — budget for it)
- [ ] If there's time: sketch what an offline RPM/dnf mirror for the RHEL/Rocky targets would need (`reposync` + `createrepo` on a box with internet, staged the same way `bootstrap.sh` stages debs) — this repo doesn't have one yet and `configure-rhel.yml`'s `dnf` tasks will need it once you're actually air-gapped
- [ ] Commit and push everything: updated `vars.yml`, `vm_catalog.yml`, `hosts.yml`, vault (encrypted), any playbook fixes
- [ ] Update `docs/autoserver-design.md` and this plan with anything that turned out differently than documented (template name, real IP ranges, permission gotchas) — future-you (and the air-gapped rebuild) will need it accurate

**Done when:** the repo reflects reality, the vault is encrypted, and you have a documented, working path from "empty vCenter template" to "configured VM" that someone else could follow.

---

## Known gaps this plan doesn't close

- **No offline RPM/dnf mirror yet** for RHEL/Rocky targets — `bootstrap.sh` only caches the autoserver's own Ubuntu/apt/pip/collection dependencies. Flagged for after this week.
- **`docs/autoserver-design.md`** predates the current `autoserver/` layout in places (old filenames like `configure-rhel-base.yml`, old `group_vars/all.yml` paths) — treat it as architectural reference, not a literal command reference; the playbook files themselves and this plan are the current source of truth.
