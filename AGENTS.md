# Infrastructure work

Project note: [[Ansible configuration management]]
Buildlog: [[ansible-baseline-log]]
Design: `ARCHITECTURE.md` says how the pieces fit, which piece owns each shared thing, and what
each must not do. Read it before changing anything.

Work arrives as a build handoff in the vault's `05_Agents/handoffs/`, and the handoff names its
own project note and buildlog when they differ from the ones above.

## Checks

Run these from `ansible/`, where `ansible.cfg` sets the inventory and the relative roles path,
inside the `dev` container:

- `ansible-lint`
- `for playbook in playbooks/*.yml; do ansible-playbook --syntax-check "$playbook"; done`

Run the Python tests from the repository root inside `dev`:

- `python3 -m pytest ansible/tests`

CI in `.github/workflows/ci.yml` runs these checks on every pull request and every branch push.
The `main` ruleset requires the lint and syntax jobs by name. Report the
checks you actually ran, with their output.

## Live runs

A live playbook run needs my say-so; never start one as a routine check. Rehearse first with
`--check --diff` against one `--limit` host. Each role's verify tasks and a second run that
reports `changed=0` are the proof a role works. Before Tailscale SSH work, run
`ssh keepbreath0@<host> true` and wait for approval if it prints a link, because Ansible hides
that prompt and an unapproved check looks like a hang.
