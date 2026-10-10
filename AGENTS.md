# Infrastructure work

Project note: [[Ansible configuration management]]
Buildlog: [[ansible-baseline-log]]

The Ansible baseline is a walkthrough: Mark writes each file while Codex
explains and reviews. Run `ansible-lint` and
`ansible-playbook --syntax-check playbooks/baseline.yml` from `ansible/`, where
`ansible.cfg` sets the inventory and relative roles path. This repository has
no GitHub Actions workflow at present; report the actual local checks run.
The baseline role's live verification and second-run no-change check need an
authorized host run. Before Tailscale SSH work, use the visible check command
and wait for approval if it prints a link. Do not start a live playbook as a
routine syntax check.
