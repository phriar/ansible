# DevSecOps Learning Path

A curated watch list for understanding the pipeline this project is building toward: deploy and configure VMs with Ansible, then run a pipeline that checks the code, then checks the actual configuration on the deployed VMs.

---

## What you're building, in plain terms

The pipeline has two distinct checkpoints:

1. **"Checks the code"** — static analysis run in CI on every push, before anything touches vCenter: `ansible-lint`/`yamllint` for syntax and best-practice issues, plus a secrets scanner so a plaintext vault never slips into a commit.
2. **"Checks the configuration on the VMs"** — this is a category called **infrastructure testing / compliance-as-code**. The two standard tools are **Testinfra** (Python, pairs naturally with Ansible/Molecule) and **InSpec** (Chef's tool, broader industry adoption). You write assertions like "port 22 is listening," "this user is in the wheel group," "this service is enabled" — then run them against the real, deployed VM after your playbook finishes, not just in a sandbox.

**Molecule** is the piece that ties both together for Ansible specifically: it spins up a throwaway container/VM, runs your role against it, then runs Testinfra assertions against that throwaway target — so you get the same style of check in CI *and* against your real VMs later.

---

## Watch in this order

### 1. Absolute overview (dummies-level)

- [What is DevOps? | DevOps Explained for Beginners](https://www.youtube.com/watch?v=4xsKrqO9pvk) — short, non-tool-specific
- [DevSecOps Explained | Secure CI/CD Pipeline for Beginners](https://www.youtube.com/watch?v=rnwwTXKtsHU) — adds the "Sec" layer conceptually

### 2. Code-check stage: linting your playbooks

- [Ansible 101 - Episode 7 - Molecule Testing and Linting and Ansible Galaxy](https://www.youtube.com/watch?v=FaXVZ60o8L8) — Jeff Geerling is a well-known, credible source in the Ansible community specifically
- [Write Better Ansible Playbooks with Ansible Lint](https://www.youtube.com/watch?v=l0TseMm1WJY)

### 3. Config-check stage: testing what actually landed on the VM

- [Ansible uses Testinfra test infrastructure](https://www.youtube.com/watch?v=DNZZmN38980) — this is the exact concept described above
- [Introduction to InSpec Part 1 - InSpec Baseline](https://www.youtube.com/watch?v=2n9jA-PASdI) — the alternative/complementary tool, more common in compliance-heavy shops

### 4. Putting code-check + config-check into one CI pipeline

- [Ansible 101 - Episode 8 - Playbook testing with Molecule and GitHub Actions CI](https://www.youtube.com/watch?v=CYghlf-6Opc) — close to the end state: lint → Molecule → Testinfra, wired into GitHub Actions
- [Continuous Testing with Molecule, Ansible, and GitHub Actions](https://www.youtube.com/watch?v=93urFkaJQ44)
- [Master CI/CD with GitHub Actions and Ansible | Step-by-Step Guide](https://www.youtube.com/watch?v=6TwHuWLpwUM) — this repo already lives on GitHub, so GitHub Actions is the natural CI runner

### 5. Optional — if you don't already know GitHub Actions basics

- [GitHub Actions Tutorial for Beginners – CI/CD Pipeline from Scratch (2026)](https://www.youtube.com/watch?v=0PbxpIao_EU)

---

## Caveat: air-gapped CI

GitHub Actions' own runners live on the internet and can't reach the air-gapped vCenter environment once this project goes fully offline. At that point you'd need a **self-hosted runner** (e.g., a small service on the autoserver itself) to run the pipeline against real hardware — a later-phase problem, not something to solve during the initial bring-up week (see `docs/bringup-plan.md`).
