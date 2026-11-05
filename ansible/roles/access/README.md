# access

This role decides who can log in to a machine and how. It creates the admin account and
sets its password, puts the account's SSH key in a place only root can change, checks that
no ordinary account can use sudo without a password, and installs the sshd hardening
drop-in.

It is separate from `baseline` because these are the only tasks in the estate that can
lock a machine out (decision #36). Everything in `baseline` fails safe: a mistake there
leaves a working machine with a problem. A mistake here can leave a machine nobody can log
in to. Keeping the two apart means `baseline` can be run freely, and this role is run on
purpose, against one host at a time.

The by-hand version is steps 1a and 6 of `server-bootstrap.md` in the operational manual.

## What it does, in order

1. Two checks run before anything changes. The first stops the run if `access_admin_user`
   is null or is not a plain lowercase account name. The name becomes part of a file path,
   so a name containing a slash would put the key somewhere sshd never reads. The second
   stops the run if `image_build` is unset, is not a real true or false, or is true on a
   machine that also has an admin account.
2. `tasks/admin.yml` creates the admin account if it is missing, adds it to `wheel`
   without removing it from any other group, and sets its password from a hash stored in
   the vault. It never sets a uid, because the machines number their
   accounts differently (decision #35).
3. `tasks/keys.yml` puts the account's SSH key where only root can change it. It creates
   `/etc/ssh/authorized_keys/`, copies `files/admin.pub` to
   `/etc/ssh/authorized_keys/<admin account>`, both owned by root, and installs
   `11-authorized-keys.conf`, which tells sshd to read keys from there. Only root can write
   to that directory, so someone who breaks into the admin account cannot add a key of
   their own (decision #37). The copy replaces the whole file, so a key added by hand is
   removed on the next run.
4. `tasks/nopasswd.yml` asks `cvtsudoers` for sudo's parsed JSON policy and passes it to
   `files/sudo-nopasswd-check.py`. The check catches command rules with `NOPASSWD` and
   `Defaults !authenticate`, including user-bound defaults and rules continued across
   lines. It stops the run if any entry lets an account or group other than exactly the
   `root` user skip a password. Root's own rule, which cloud-init wrote on the droplets
   built in August, is allowed (decision #38). Droplets built from step 1a's user-data do
   not get it. A JSON parse error also stops the run, so unreadable policy never reports
   safe.
5. `tasks/sshd.yml` installs `10-hardening.conf`, which turns off password and
   keyboard-interactive login and limits root to key login only.
6. `tasks/verify.yml` checks that those sshd settings took effect. It runs after the
   handlers have checked and reloaded sshd.

Steps 2 and 3 are skipped on a machine with no admin account. Steps 1, 4, 5 and 6 run
everywhere.

## Machines with no admin account

An image build and a staging box have no admin account. An image must not carry a
password, because every machine made from it would share it. A staging box is built and
destroyed by a robot that logs in as root, so nobody needs a personal account on it
(decisions #6, #7 and #32).

On those machines the role skips the account, the key and `11-authorized-keys.conf`.
Skipping the drop-in is what keeps them reachable. Setting where sshd reads keys replaces
the default list rather than adding to it, so on a machine with no admin account the
drop-in would stop sshd reading `/root/.ssh/authorized_keys`, which holds the only key
anyone could log in with (decision #49).

On a machine that does have an admin account, root's key login stops working after the
first run. That is intended. From then on Ansible connects as the admin account.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `access_admin_user` | `keepbreath0` | The admin account. Set it to `""` on a machine with no admin account. |

`meta/argument_specs.yml` is the authoritative list. Its `default:` documents the value
but does not set it. The value comes from `defaults/main.yml`, so the two must be kept the
same by hand.

Two more variables are read by this role and set elsewhere:

- `access_admin_password_hash` is set in `group_vars/all.yml`. It reads a hidden custom
  field named `hash` from the host's vault item, `keepbreath0 sudo (<inventory name>)`.
  The lookup only runs when the admin account task reads it, so a machine with no admin
  account never asks the vault.
- `image_build` describes the run rather than either role, so it is set once: in
  `group_vars/all.yml` for the machines in this repository, and in the inventory of any
  Packer or staging run. It has no default anywhere, on purpose (decision #48). A Packer
  inventory kept outside `ansible/` does not load `group_vars/all.yml`, so if `false` were
  the default, a forgotten setting would let an image build run as if it were a live
  machine.

Write an empty value as `""`. A bare `key:` is YAML null, which the first check rejects.

## The password hash in the vault

The `user` module sets a password from a hash, not from the password itself. The hash is
stored once, beside the password, so every run hands the module the same string and a
second run reports no change (decision #34).

Each host's vault item needs a hidden custom field named `hash`, made with that host's own
algorithm. The AlmaLinux 10 machines use yescrypt and the AlmaLinux 9 droplets use SHA-512.
As of 7 October only the hub's item has one. A new droplet needs its own item and hash
before this role runs against it.

## What a robot inventory sets

On top of what the `baseline` README lists:

| Setting | Value | Why |
| --- | --- | --- |
| `access_admin_user` | `""` | An image and a staging box get no admin account. |
| `image_build` | `true` when baking an image, `false` otherwise | The first check refuses to run without it. Set it as a real boolean. `-e image_build=yes` on the command line arrives as text and fails; use `-e '{"image_build": true}'`. |

## Running it

From the `ansible/` directory, with the vault unlocked:

```bash
ansible-playbook playbooks/access.yml --limit hub
```

Use `--limit` when targeting more than one machine. The playbook's first task refuses a
multi-machine run without an explicit limit before reading any vault item.

`playbooks/site.yml` runs `baseline` and then this role, for a complete build.

Before running it against a machine for the first time, know how you will get back in if
it goes wrong. The hub, vaultserv and control can be reached over Tailscale SSH, which does
not use sshd at all. A droplet that is not on the tailnet has only DigitalOcean's web
console.

A second run must report no changes.

## What it checks before it finishes

`tasks/verify.yml` runs `sshd -T`, which makes sshd read its configuration files and print
the settings that win. The run fails unless root login is key-only, password and
keyboard-interactive login are off, and, on a machine with an admin account, keys are read
from `/etc/ssh/authorized_keys/`.

This catches a drop-in that is in place but overridden. sshd takes the first value it finds
for each setting, so a file that sorts earlier in `/etc/ssh/sshd_config.d/` would win
without any error.

It cannot see the running sshd. `sshd -T` reads the files again in a new process, so if
the reload handler had failed, this check would still pass. It also reports only the
settings that apply to everyone, so a `Match` block that turned password login back on for
some addresses would not show. No machine had one when that was checked on 19 September
2026.

The check is skipped under `--check`, because a rehearsal writes nothing.

## The sudo policy check

`cvtsudoers -f json /etc/sudoers` follows sudo's configured includes and parses aliases,
continued lines, command tags and `Defaults` bindings the same way sudo does. The Python
check reads that JSON rather than trying to reconstruct policy from individual text lines.
It exits 0 only when it can parse the document and finds no passwordless entry for anything
other than exactly the `root` user. Findings exit 1, and malformed or unexpected JSON exits
2. Both nonzero results stop the role and print the check's lines.

Nothing in this repository sets up the first run against a brand-new machine yet. That run
has to connect as root (decision #34), and `inventory.ini` connects as `keepbreath0`
everywhere.
