# baseline

What every machine gets, whatever its job. Automatic security updates, an SSH hardening
drop-in, swap where there is none, fail2ban with the sshd jail, firewalld installed and
enabled with cockpit removed from the default zone, Podman prepared for rootless
containers, and a persistent capped journal.

The by-hand version is `server-bootstrap.md` in the operational manual; this role is that
procedure written down so a machine can be rebuilt without anyone remembering it.

**Not in this role.** Patching, because a role that upgrades packages can never report no
changes on a second run; it will be `playbooks/patch.yml`, which is not written yet.
Application ports, which belong to the role for the machine that serves them.

**Planned to move out.** The SSH hardening drop-in is here and working. The admin account
is here only as a `debug` placeholder. Both move to an `access` role, which does not exist
yet. They are the only tasks that
can make a machine unreachable, and separating them means the rest can be applied freely.
Until that happens, treat any run of this role as capable of touching SSH.

**Where it has run.** Every step has been proven on `hub` only, which is AlmaLinux 10.2.
Three of the five machines are AlmaLinux 9.8. A first run against one of those is a real
test, not a formality, and should be rehearsed with `--check --diff`.

**A rehearsal only works on a machine that already has the packages.** Under `--check`,
`dnf` reports that it would install a package and does not, so a later task that edits
that package's config file (`lineinfile` on `/etc/dnf/automatic.conf`) or asks systemd
about its unit fails on a machine that has never had it. The three droplets were
hand-built with every package and can be rehearsed. A machine the role has never touched,
such as `vaultserv` or a fresh droplet, cannot: first contact there is a real run under
`--limit`, and the rehearsal is the second run reporting no changes.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `baseline_container_user` | *required* | The unprivileged account that runs rootless containers on this machine. Empty means the machine has none, and lingering is skipped. Per host, in `host_vars`. |
| `baseline_admin_user` | `keepbreath0` | The admin account. Empty means the machine has none. Read by the role's opening assertions; the task that would create it is still a `debug` placeholder. |
| `baseline_image_build` | `false` | True when baking an image rather than configuring a live machine. No task reads it; the role asserts only that a build was not also given an admin account. |
| `baseline_swap_size` | `1G` | Size of the swap file created on machines that have none. |
| `baseline_firewalld_remove_cockpit` | `true` | Remove the cockpit service from the firewall's default zone. |

`meta/argument_specs.yml` is the authoritative version. It validates these before the
role's first task — note that the playbook's first play, which reads the sudo password
from the vault, has already run by then.

Write an empty value as `""`. A bare `key:` is YAML null, which passes argument
validation as a string and would then behave exactly like an empty value — meaning "this
machine has no such account" — so the role rejects null explicitly rather than letting it
silently switch something off. `baseline_image_build` is different: the argument spec
rejects a null bool before any assertion runs.

## What a robot inventory sets

A persistent machine is described by `inventory.ini` and its `host_vars`. A Packer build or
an ephemeral staging droplet brings its own inventory, because Packer's Ansible provisioner
generates one and the staging job generates one on the runner. That inventory is this
role's interface:

| Setting | Value | Why |
|---|---|---|
| `ansible_user` | `root` | The machine has no admin account yet, or never will. |
| `ansible_become` | `false` | Already root. The become-password lookup in `group_vars/all.yml` is conditional on this variable, so a host with it false never calls the vault, which a CI runner has no session for. Ansible templates that variable for every task whether or not become is in effect, so skipping the first play is not enough; the lookup itself has to be conditional. `become = True` in `ansible.cfg` does not set this variable, so an inventory that omits it gets the vault lookup. A Packer inventory kept outside `ansible/` never loads `group_vars/all.yml` at all. |
| `baseline_admin_user` | `""` | An image and a staging box get no admin account. The role asserts this when `baseline_image_build` is true. |
| `baseline_container_user` | `""` for an image; the account name for staging | An image does not know its container account yet; the name is assigned when a machine is created from it. A staging box is named for its pull request. |
| `baseline_image_build` | `true` only when baking | Accepted and reserved. No task reads it; it exists for the secret-applying tasks that will live in `access`. |

**Nothing in this repository sets that pair for any host.** `inventory.ini` puts
`ansible_user=keepbreath0` in `[all:vars]` and sets `ansible_become` nowhere, so the
first-run-as-root path that decision #34 describes has no mechanism here yet.

## Running it

From the `ansible/` directory. `ansible-lint` and `--syntax-check` only work from there,
because `roles_path` lives in `ansible/ansible.cfg`.

```bash
pip install --user -r ../requirements.txt
ansible-galaxy collection install -r collections/requirements.yml
ansible-playbook playbooks/baseline.yml --limit hub
```

The collection install is not optional: `ansible.posix` does not ship with `ansible-core`
and `tasks/firewalld.yml` uses `ansible.posix.firewalld`.

The vault must be unlocked in the shell it runs from (`vu`), because the sudo password is
read from it at run time, one item per host named `keepbreath0 sudo (<inventory name>)`.

On a machine reached over Tailscale SSH in check mode, approve the browser check with
`ssh keepbreath0@<host> true` before the first run of a session. Ansible captures SSH's
output, so an unapproved check looks like a hang rather than a prompt.

A second run must report no changes. That is the test, and it is run by hand.

## What it checks before it finishes

`tasks/verify.yml` runs last, after the handlers have been flushed, and fails the play if
the machine is not in the state the role claims to have left it in. Three checks, each
because the failure it catches is silent:

- `sshd -T` proves the hardening drop-in is the configuration that wins on parse. It
  cannot see the running daemon, and the failure message says so. It also reports only
  global values, so a `Match` block that re-enabled password login for some address
  would not show; no machine has one as of 2026-09-19.
- `fail2ban-client status sshd` proves the jail is loaded and reading the journal.
  `systemctl reload fail2ban` returns success even when the jail is rejected, so a
  `changed` from the copy task is not evidence.
- The live `system.journal` must be on disk and none in `/run`. Both
  `journalctl --disk-usage` and a path match in `journalctl --header` report a machine as
  persistent when it has fallen back to volatile.

Skipped under `--check` and during an image build, which means a rehearsal does not run
them. That is a real gap in the run that would most benefit from them.
