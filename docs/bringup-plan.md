# Autoserver Bring-Up Plan — 6 Days

A day-by-day plan for standing up the autoserver against a real vCenter environment and getting a repeatable template-clone-and-configure loop working for **both a Windows and a RHEL/Rocky VM**, at 3–5 hrs/day.

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

This is the first day touching your real vCenter, so budget time for credential/permissions back-and-forth. Goal for today is to leave with **both** template names confirmed and ready — Windows and RHEL run in parallel from here on.

- [ ] Get a vCenter service account (or your own creds) with rights to deploy/clone/power VMs in the target folder
- [ ] `ansible-vault edit autoserver/inventory/group_vars/all/vault.yml` — set `vault_vcenter_password` (and `vault_esxi_password` if you'll also test standalone ESXi). Encrypt the file if it isn't already (`ansible-vault encrypt ...`) — **do not commit it in plaintext**
- [ ] Update `autoserver/inventory/group_vars/all/vars.yml`: `vcenter_host`, `vcenter_user`, `vcenter_datacenter`, `vcenter_cluster`, `vcenter_folder` to match your environment
- [ ] Sanity-check auth without touching any VM — e.g. `community.vmware.vcenter_about_info` or `community.vmware.vmware_vm_info` in an ad-hoc play
- [ ] Find the real name of the **RHEL/Rocky template** — you'll need this for `vm_template` in `autoserver/vars/deploy-vm-template.yml`
- [ ] Find the real name of the **Windows Server template**, and confirm whether WinRM is already enabled on it (see the WinRM Prep Script in `docs/autoserver-design.md`). If it isn't, that's extra prep work — plan to knock it out today or first thing Day 4, since `configure-windows.yml` can't connect without it
- [ ] Confirm the Windows template has sysprep available/unattended answer file settings you'll need (`vm_is_windows: true` path in `deploy-vm-template.yml`) — product key, timezone index, etc.

**Done when:** an ad-hoc Ansible task against vCenter authenticates and returns real inventory data, and you have both template names plus confirmation the Windows template's WinRM is ready — no VM changes yet.

---

## Day 4 — Deploy both VMs from template

Exercise `autoserver/deploy-vm-template.yml` for both OS types today, back to back.

**RHEL/Rocky:**
- [ ] Fill in a RHEL var set for `deploy-vm-template.yml`: `vm_template`, `vcenter_datastore`, `vcenter_esxi_host`/`vcenter_cluster`, `vm_network_label`, `vm_ip`/`vm_netmask`/`vm_gateway`/`vm_dns_servers`, `vm_is_windows: false`
- [ ] Confirm the template has `open-vm-tools` + `perl` so guest customization works — see `docs/deploy-vm-template.md` if it's missing
- [ ] Dry run (`--check --diff`), then real run: `ansible-playbook autoserver/deploy-vm-template.yml -e vm_name=<name> -e vm_ip=<ip>`
- [ ] Add it to `autoserver/inventory/hosts.yml` under `rhel`, confirm SSH

**Windows:**
- [ ] Same, with `vm_is_windows: true` and the Windows template name, product key/timezone index, `vm_network_label`/IP settings for that VM
- [ ] Dry run, then real run
- [ ] Add it to `autoserver/inventory/hosts.yml` under `windows`, confirm WinRM: `ansible <win_vm_name> -m ansible.windows.win_ping --ask-vault-pass`

If one side stalls (a vCenter quirk, a missing template setting), don't let it block the other — get whichever one is working done first, then come back.

**Done when:** you have one running RHEL VM and one running Windows VM, both cloned from their real vCenter templates today, both reachable.

---

## Day 5 — Post-deploy configuration, both OSes

Exercise `configure-rhel.yml` and `configure-windows.yml` against yesterday's two VMs.

- [ ] `ansible-playbook autoserver/configure-rhel.yml -l <rhel_vm_name> --ask-vault-pass`
- [ ] `ansible-playbook autoserver/configure-windows.yml -l <win_vm_name> --ask-vault-pass`
- [ ] Verify roles independently if something fails: `--tags rename`, `--tags network`, `--tags domain` (domain join is off by default — `-e domain_join_enabled=true` to test it, see `docs/windows-domain-join.md`)
- [ ] Fix whatever breaks against your real environment — DNS, gateway reachability, sudo/WinRM auth, AD join permissions are the usual suspects, and they tend to differ between the two OSes
- [ ] Re-run both against their already-configured VMs to confirm idempotency — running twice shouldn't change anything the second time

**Done when:** `deploy-vm-template.yml` → `configure-rhel.yml`/`configure-windows.yml` is a clean, repeatable, two-command loop for **both** OS types, from template to configured VM.

---

## Day 6 — Buffer, offline validation, and write down what changed

- [ ] Catch-up day for whatever slipped from Days 3–5 — with both OSes in scope this week, this is the day that absorbs it; if only one of RHEL/Windows made it through Day 5 clean, this is where the other one gets finished
- [ ] If there's time: sketch what an offline RPM/dnf mirror for the RHEL/Rocky targets would need (`reposync` + `createrepo` on a box with internet, staged the same way `bootstrap.sh` stages debs) — this repo doesn't have one yet and `configure-rhel.yml`'s `dnf` tasks will need it once you're actually air-gapped
- [ ] Commit and push everything: updated `vars.yml`, `vm_catalog.yml`, `hosts.yml`, vault (encrypted), any playbook fixes
- [ ] Update `docs/autoserver-design.md` and this plan with anything that turned out differently than documented (template name, real IP ranges, permission gotchas) — future-you (and the air-gapped rebuild) will need it accurate

**Done when:** the repo reflects reality, the vault is encrypted, and you have a documented, working path from "empty vCenter template" to "configured VM" that someone else could follow.

---

## Known gaps this plan doesn't close

- **No offline RPM/dnf mirror yet** for RHEL/Rocky targets — `bootstrap.sh` only caches the autoserver's own Ubuntu/apt/pip/collection dependencies. Flagged for after this week.
- **`docs/autoserver-design.md`** predates the current `autoserver/` layout in places (old filenames like `configure-rhel-base.yml`, old `group_vars/all.yml` paths) — treat it as architectural reference, not a literal command reference; the playbook files themselves and this plan are the current source of truth.
