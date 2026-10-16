# baseline

This role sets up what every machine gets, whatever its job. It installs automatic security
updates, adds swap on a machine that has none, and sets up fail2ban to ban addresses that
keep failing SSH logins. It installs and enables firewalld with cockpit removed from the
default zone, prepares Podman for rootless containers, and makes the journal persistent
with a size cap. It also installs chrony for time sync, bounds how much disk core dumps can
use, and blacklists filesystem modules nothing here uses. Two assertions stop the run if
SELinux is not enforcing or if an enabled package repository's effective configuration has
signature checking turned off.

The by-hand version is `server-bootstrap.md` in the operational manual. This role is that
procedure written down, so a machine can be rebuilt without anyone having to remember it.

The repository check uses DNF's Python interface rather than reading `.repo` files as text.
That reports the setting DNF will actually use, including `false`, `no` and a repository
that inherits `gpgcheck=0` from `/etc/dnf/dnf.conf`. DNF reads an indented line as a
continuation of the setting above it, so an indented `gpgcheck=0` does not turn checking off.
Disabled repositories are not checked because DNF cannot install from them. `files/repo-gpgcheck-check.py` exits 0 when
every enabled repository is safe, 1 after printing each unsafe repository id, and 2 when DNF
cannot be read safely. Both nonzero results stop the role (decision #39).

## Not in this role

- Who can log in and how. The admin account, its SSH key, the sudo check and the sshd
  hardening drop-in are in the `access` role. Those are the only tasks that can lock a
  machine out, so they are kept apart and run on purpose.
- Patching. A role that upgrades packages can never report no changes on a second run, so
  patching will be `playbooks/patch.yml`, which is not written yet.
- Application ports. Which ports a machine opens depends on its job, so they belong to the
  role for that kind of machine.

## Where it has run

Every step has been proven on `hub` only, which is AlmaLinux 10.2. The droplets are
AlmaLinux 9.8, so the first droplet the roles build is the first test of the 9.8 path.

A rehearsal only works on a machine that already has the packages. Under `--check`,
`dnf` reports that it would install a package but does not install it. A later task that
edits that package's config file, such as the `lineinfile` on `/etc/dnf/automatic.conf`,
or asks systemd about its service, then fails because the package is not there. So on a
machine the role has never touched, such as a fresh droplet, the first contact is a real
run under `--limit`, and the check there is a second run that reports no changes.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `baseline_container_user` | *required* | The unprivileged account that runs rootless containers on this machine. Set it per host in `host_vars`. An empty value means the machine has no container account, and lingering is skipped. |
| `baseline_swap_size` | `1G` | The size of the swap file created on a machine that has no swap. |
| `baseline_firewalld_remove_cockpit` | `true` | Whether to remove the cockpit service from the firewall's default zone. |
| `baseline_blacklist_fs_modules` | `[cramfs, freevxfs, jffs2, hfs, hfsplus]` | Filesystem modules written to `/etc/modprobe.d/` as `install <mod> /bin/false` plus `blacklist <mod>`. None of them is built into the AlmaLinux 9 or 10 kernel. The file exists so that the CIS and STIG scanners report clean. `udf` and `squashfs` are left out because the VMs mount ISO images. |

`meta/argument_specs.yml` is the authoritative list. Ansible checks these variables against
it before the role's first task. By then the playbook's first play, which reads the sudo
password from the vault, has already run.

Write an empty value as `""`. A bare `key:` with nothing after it is YAML null. Null passes
argument validation as a string and then behaves exactly like an empty value, which would
quietly mean "this machine has no container account". So the role rejects null explicitly.

This role also reads one variable it does not declare. `image_build` is true when the run
is baking a reusable image rather than configuring a live machine. It describes the run, not
either role, so it is set once, in `group_vars/all.yml` for the machines in this repository
and in the inventory of any Packer or staging run. This role reads it in `verify.yml`, which
is skipped during an image build. It has no default anywhere, so a run that never sets it
stops with the error `'image_build' is undefined`.

## What a robot inventory sets

A persistent machine is described by `inventory.ini` and its `host_vars`. A Packer build or
a short-lived staging droplet brings its own inventory, because Packer's Ansible provisioner
generates one and the staging job generates one on the runner. That inventory has to set
these:

| Setting | Value | Why |
| --- | --- | --- |
| `ansible_user` | `root` | The machine has no admin account yet, or never will. |
| `ansible_become` | `false` | Ansible is already root. The sudo password lookup in `group_vars/all.yml` only runs when this is true, so a host with it false never asks the vault, which a CI runner has no session for. `become = True` in `ansible.cfg` does not set this variable, so an inventory that leaves it out still gets the vault lookup. A Packer inventory kept outside `ansible/` never loads `group_vars/all.yml` at all. |
| `image_build` | `true` when baking an image, `false` otherwise | See above. A Packer inventory has to set it, because it does not load `group_vars/all.yml`. |
| `baseline_container_user` | `""` for an image, the account name for a staging box | An image does not know its container account yet, because the name is assigned when a machine is created from it. A staging box is named for its pull request. |

The `access` role's README lists what the same inventory sets for that role.

Nothing in this repository sets `ansible_user=root` and `ansible_become=false` for any
host yet. `inventory.ini` puts `ansible_user=keepbreath0` in `[all:vars]` and sets
`ansible_become` nowhere. So the first run as root that decision #34 describes has no
mechanism here yet.

## Running it

From the `ansible/` directory. `ansible-lint` and `--syntax-check` only work from there,
because `roles_path` is set in `ansible/ansible.cfg`.

```bash
pip install --user -r ../requirements.txt
ansible-galaxy collection install -r collections/requirements.yml
ansible-playbook playbooks/baseline.yml --limit hub
```

`playbooks/site.yml` runs this role and then `access`, for a complete build.

The collection install is not optional. `ansible.posix` does not ship with `ansible-core`,
and `tasks/firewalld.yml` uses `ansible.posix.firewalld`.

The vault must be unlocked in the shell the playbook runs from (`vu`), because the sudo
password is read from it at run time. There is one item per host, named
`keepbreath0 sudo (<inventory name>)`.

On a machine reached over Tailscale SSH in check mode, run `ssh keepbreath0@<host> true`
before the first playbook of a session and approve the browser link it prints. Ansible
hides SSH's output, so an unapproved check looks like a hang rather than a prompt.

A second run must report no changes. That is the test, and it is checked by hand.

## What it checks before it finishes

`tasks/verify.yml` runs last, after the handlers have been flushed, and fails the play if
the machine is not in the state the role says it left. There are two checks, and each one
exists because the failure it catches is silent:

- `fail2ban-client status sshd` proves the sshd jail is loaded and reading the journal.
  `systemctl reload fail2ban` returns success even when fail2ban rejects the jail, so the
  copy task reporting a change is not evidence that the jail works.
- The live journal file, `system.journal`, must be on disk and not in `/run`. Both
  `journalctl --disk-usage` and a path match in `journalctl --header` report a machine as
  persistent when it has fallen back to keeping the journal in memory.

The check that the sshd hardening is in effect is in the `access` role, beside the
drop-in it checks.

Both checks are skipped under `--check` and during an image build. A rehearsal therefore
does not run them, even though a rehearsal is where they would be most useful.
