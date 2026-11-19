#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=webtest
site=/srv/keepbreathing
api=/srv/keepbreath-contact-api
home=/home/$user
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'webtest already exists'; fi
if test -e "$site" || test -L "$site"; then fail '/srv/keepbreathing already exists'; fi
if test -e "$api" || test -L "$api"; then fail '/srv/keepbreath-contact-api already exists'; fi

work=$(mktemp -d)
created_account=false
created_site=false
created_api=false
undo_add 'remove web driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_add 'remove driver-created web account' undo_account
undo_account() {
  if $created_account && id -u "$user" >/dev/null 2>&1; then
    if ! runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1; then
      cat "$work/account-cleanup.log" >&2
      return 1
    fi
    if grep -vFx 'userdel: webtest mail spool (/var/mail/webtest) not found' "$work/account-cleanup.log" >"$work/unexpected-cleanup.log"; then
      cat "$work/unexpected-cleanup.log" >&2
      return 1
    fi
  fi
}
undo_add 'remove driver-created site checkout' undo_site
undo_site() { if $created_site; then rm -rf -- "$site"; fi; }
undo_add 'remove driver-created contact API checkout' undo_api
undo_api() { if $created_api; then rm -rf -- "$api"; fi; }
undo_install
runner_save_environment

as_user() {
  (
    cd "$home"
    HOME="$home" USER="$user" LOGNAME="$user" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
      XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
  )
}

play() {
  local label=$1 site_ref=$2 api_ref=$3
  shift 3
  last_log="$work/$label.log"
  ansible-playbook -i localhost, tests/web/role.yml \
    -e "web_container_user=$user" -e "web_site_ref=$site_ref" \
    -e "web_contact_api_ref=$api_ref" \
    -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587' \
    -e 'web_smtp_user=contact@keepbreath.ing' \
    -e 'web_smtp_host_address=10.128.0.4' "$@" >"$last_log" 2>&1
}
recap() {
  grep -Eq "localhost[[:space:]]+:.*changed=$2 .*failed=0" "$1" || {
    tail -45 "$1"
    fail "$1 recap must have changed=$2 and failed=0"
  }
}
changed_task() {
  python3 - "$1" "$2" <<'PY' || fail "$2 did not report changed"
import pathlib, re, sys
log, title = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
task = re.search(r'TASK \[web : ' + re.escape(title) + r'\][^\n]*\n(.*?)(?=\nTASK \[|\nPLAY RECAP)', log, re.S)
assert task and re.search(r'^changed: \[localhost\]', task.group(1), re.M)
PY
}
head_at() {
  runuser -u "$user" -- git -C "$1" rev-parse --short=7 HEAD
}
expect_head() {
  local actual
  actual=$(head_at "$1")
  test "$actual" = "$2" || fail "$1 HEAD was $actual, expected $2"
}

if ansible localhost -i localhost, -c local --playbook-dir tests/web \
  -m ansible.builtin.include_role -a name=web \
  -e 'web_container_user=webabsent' -e 'web_site_ref=949b89f' \
  -e 'web_contact_api_ref=0c856b9' \
  -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587' \
  -e 'web_smtp_user=contact@keepbreath.ing' \
  -e 'web_smtp_host_address=10.128.0.4' >"$work/missing-account.log" 2>&1; then
  fail 'missing account was accepted'
fi
grep -F 'web: the account webabsent does not exist; run the web role'"'"'s account entry point before baseline' "$work/missing-account.log" >/dev/null || fail 'missing account message differs'
if id -u webabsent >/dev/null 2>&1; then fail 'missing account was created'; fi
test ! -e "$site" && test ! -e "$api" || fail 'missing account made a checkout'
printf 'PASS missing account: role fails before making a checkout\n'

created_account=true
created_site=true
created_api=true
if ! play fresh-check 949b89f 0c856b9 --check --diff; then tail -45 "$last_log"; fail 'fresh check failed'; fi
recap "$last_log" 1
if id -u "$user" >/dev/null 2>&1; then fail 'fresh check created account'; fi
test ! -e "$site" && test ! -e "$api" || fail 'fresh check created a checkout'
printf 'PASS fresh check: changed=1, nothing created\n'

for entry in 'name=web tasks_from=account' 'name=baseline tasks_from=container-account'; do
  extra=(-e "web_container_user=$user" -e "baseline_container_user=$user"
    -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587'
    -e 'web_smtp_user=contact@keepbreath.ing'
    -e 'web_smtp_host_address=10.128.0.4')
  if ! ansible localhost -i localhost, -c local --playbook-dir tests/web \
    -m ansible.builtin.include_role -a "$entry" "${extra[@]}" \
    >"$work/account-setup.log" 2>&1; then
    tail -45 "$work/account-setup.log"
    fail "account setup failed: $entry"
  fi
done
if ! play account-check 949b89f 0c856b9 --check --diff; then
  tail -45 "$last_log"
  fail 'account check failed'
fi
for prediction in \
  'Would clone https://github.com/sh4i-yurei/keepbreathing.git at 949b89f into /srv/keepbreathing' \
  'Would clone https://github.com/sh4i-yurei/keepbreath-contact-api.git at 0c856b9 into /srv/keepbreath-contact-api' \
  'Would create keepbreath-net'; do
  grep -F "$prediction" "$last_log" >/dev/null || fail "missing prediction: $prediction"
done
for task in "Make the account's Quadlet folder" "Make the worker's drop-in folder" "Write the worker's relay drop-in"; do
  changed_task "$last_log" "$task"
done
test ! -e "$site" && test ! -e "$api" || fail 'account check created a checkout'
if as_user podman network inspect keepbreath-net >"$work/missing-network.json" 2>&1; then
  fail 'account check created the network'
else
  test "$?" = 125 || fail 'missing network inspect did not exit 125'
fi
test ! -e "$home/.config/containers/systemd/contact-worker.container.d" || fail 'account check created the drop-in folder'
printf 'PASS account check: clones, network and drop-in predicted without writes\n'

as_user podman network create --subnet 10.89.0.0/24 --gateway 10.89.0.1 keepbreath-net >"$work/network-create.log"
as_user podman network inspect keepbreath-net >"$work/network-before.json"
network_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["id"])' "$work/network-before.json")

if ! play first 949b89f 0c856b9; then tail -45 "$last_log"; fail 'first run failed'; fi
test "$(grep -c "^$user:" /etc/subuid)" = 1 || fail 'subuid entries differ'
test "$(grep -c "^$user:" /etc/subgid)" = 1 || fail 'subgid entries differ'
for path in "$site" "$api"; do
  test "$(stat -c '%a %U:%G' "$path")" = '755 webtest:webtest' || fail "$path ownership or mode differs"
done
expect_head "$site" 949b89f
expect_head "$api" 0c856b9
as_user podman network inspect keepbreath-net >"$work/network-after.json"
python3 - "$work/network-after.json" "$network_id" <<'PY' || fail 'matching network changed'
import json, sys
network = json.load(open(sys.argv[1]))[0]
assert network['id'] == sys.argv[2]
assert network['subnets'] == [{'subnet': '10.89.0.0/24', 'gateway': '10.89.0.1'}]
assert network['dns_enabled'] is True
PY
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd")" = '700 webtest:webtest' || fail 'Quadlet folder metadata differs'
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd/contact-worker.container.d")" = '755 webtest:webtest' || fail 'drop-in folder metadata differs'
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf")" = '644 webtest:webtest' || fail 'relay drop-in metadata differs'
cmp -s "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf" <(printf '[Container]\nEnvironment=CONTACT_SMTP_HOST=mail.keepbreath.ing\nEnvironment=CONTACT_SMTP_PORT=2587\nEnvironment=CONTACT_SMTP_USER=contact@keepbreath.ing\nAddHost=mail.keepbreath.ing:10.128.0.4\n') || fail 'relay drop-in bytes differ'
printf 'PASS first run: account, subordinate IDs, paths and refs\n'

mkdir "$work/quadlet"
cp -a "$api/deploy/quadlet/." "$work/quadlet/"
cp -a "$home/.config/containers/systemd/contact-worker.container.d" "$work/quadlet/"
chown -R "$user:$user" "$work/quadlet"
chmod 755 "$work"
if ! as_user env "QUADLET_UNIT_DIRS=$work/quadlet" /usr/libexec/podman/quadlet -dryrun -user >"$work/quadlet.log" 2>&1; then
  tail -45 "$work/quadlet.log"
  fail 'Quadlet dry run failed'
fi
python3 - "$work/quadlet.log" <<'PY' || fail 'Quadlet worker relay flags differ'
import pathlib, shlex, sys
output = pathlib.Path(sys.argv[1]).read_text()
worker = output.split('---contact-worker.service---', 1)[1].split('---', 1)[0]
exec_start = next(line.split('=', 1)[1] for line in worker.splitlines() if line.startswith('ExecStart='))
args = shlex.split(exec_start)
for flag, value in [
    ('--add-host', 'mail.keepbreath.ing:10.128.0.4'),
    ('--env', 'CONTACT_SMTP_HOST=mail.keepbreath.ing'),
    ('--env', 'CONTACT_SMTP_PORT=2587'),
    ('--env', 'CONTACT_SMTP_USER=contact@keepbreath.ing'),
]:
    assert sum(args[index:index + 2] == [flag, value] for index in range(len(args) - 1)) == 1, (flag, value, args)
assert args.count('--add-host') == 1
assert sum(args[index] == '--env' and args[index + 1].startswith('CONTACT_SMTP_') for index in range(len(args) - 1)) == 3
PY
rm -rf -- "$work/quadlet"
printf 'PASS Quadlet: one relay pin and one of each setting\n'

if ! play second 949b89f 0c856b9; then tail -45 "$last_log"; fail 'second run failed'; fi
recap "$last_log" 0
printf 'PASS second run: changed=0\n'

if ! play repeat-check 949b89f 0c856b9 --check --diff; then tail -45 "$last_log"; fail 'repeat check failed'; fi
recap "$last_log" 0
printf 'PASS check mode after a run: changed=0\n'

if ! play different-refs 63ae43b 2bf47f7; then tail -45 "$last_log"; fail 'different refs failed'; fi
recap "$last_log" 0
expect_head "$site" 949b89f
expect_head "$api" 0c856b9
printf 'PASS existing checkouts: both HEADs stay put\n'

as_user sh -c 'printf "[Container]\nEnvironment=SSL_CERT_FILE=/x\n" > "$HOME/.config/containers/systemd/contact-worker.container.d/60-staging-ca.conf"'
other_dropin="$home/.config/containers/systemd/contact-worker.container.d/60-staging-ca.conf"
other_hash=$(sha256sum "$other_dropin" | cut -d' ' -f1)
if ! play no-address 949b89f 0c856b9 -e 'web_smtp_host_address='; then tail -45 "$last_log"; fail 'empty address failed'; fi
recap "$last_log" 1
cmp -s "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf" <(printf '[Container]\nEnvironment=CONTACT_SMTP_HOST=mail.keepbreath.ing\nEnvironment=CONTACT_SMTP_PORT=2587\nEnvironment=CONTACT_SMTP_USER=contact@keepbreath.ing\n') || fail 'empty-address drop-in bytes differ'
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf")" = '644 webtest:webtest' || fail 'empty-address drop-in metadata differs'
test "$(sha256sum "$other_dropin" | cut -d' ' -f1)" = "$other_hash" || fail 'other drop-in changed'
printf 'PASS empty address: pin removed and other drop-in preserved\n'

as_user podman network rm keepbreath-net >"$work/network-rm.log"
as_user podman network create --subnet 10.90.0.0/24 keepbreath-net >"$work/network-wrong.log"
if play wrong-network 949b89f 0c856b9; then fail 'mismatched network was accepted'; fi
grep -F 'web: keepbreath-net exists with other settings; the role never changes an existing network, so fix it by hand (Ansible configuration management decision 61.4)' "$last_log" >/dev/null || fail 'mismatched network message differs'
as_user podman network inspect keepbreath-net >"$work/network-wrong.json"
python3 - "$work/network-wrong.json" <<'PY' || fail 'mismatched network changed'
import json, sys
assert json.load(open(sys.argv[1]))[0]['subnets'][0]['subnet'] == '10.90.0.0/24'
PY
printf 'PASS mismatched network: refused unchanged\n'

as_user podman network rm keepbreath-net >"$work/network-rm.log"
as_user podman network create --subnet 10.89.0.0/24 --gateway 10.89.0.1 keepbreath-net >"$work/network-create.log"
network_file="$home/.local/share/containers/storage/networks/keepbreath-net.json"
printf '{broken' >"$network_file"
if play corrupt-network 949b89f 0c856b9; then fail 'corrupt network was accepted'; fi
grep -F "web: podman network inspect keepbreath-net failed in a way that isn't 'network not found'" "$last_log" >/dev/null || fail 'corrupt network message differs'
test "$(cat "$network_file")" = '{broken' || fail 'corrupt network was overwritten'
printf 'PASS corrupt network: refused unchanged\n'

rm -rf -- "$site"
if play old-site 63ae43b 0c856b9; then fail 'old site was accepted'; fi
grep -F 'web: the site checkout /srv/keepbreathing does not publish 127.0.0.1:8080 (no line PublishPort=127.0.0.1:8080:8080 in deploy/quadlet/keepbreath.container); deploy keepbreathing #39, the loopback server, first (Ansible configuration management decision 61.9)' "$last_log" >/dev/null || fail 'old site failure differs'
expect_head "$api" 0c856b9
printf 'PASS old site: loopback guard rejects 63ae43b\n'

rm -rf -- "$site" "$api"
mkdir "$api"
printf stray >"$api/stray"
if play stray-api 949b89f 0c856b9; then fail 'stray API folder was accepted'; fi
grep -F 'web: /srv/keepbreath-contact-api exists but is not a git checkout; move it aside before running the web role' "$last_log" >/dev/null || fail 'stray API failure differs'
test "$(cat "$api/stray")" = stray || fail 'stray API file changed'
test ! -e "$site" || fail 'site was cloned before stray API refusal'
if grep -F 'already exists and is not an empty directory' "$last_log" >/dev/null; then fail 'git handled the stray API folder'; fi
printf 'PASS stray API folder: refused before either clone\n'

mv "$api" "$site"
if play stray-site 949b89f 0c856b9; then fail 'stray site folder was accepted'; fi
grep -F 'web: /srv/keepbreathing exists but is not a git checkout; move it aside before running the web role' "$last_log" >/dev/null || fail 'stray site failure differs'
test ! -e "$api" || fail 'API was cloned before stray site refusal'
printf 'PASS stray site folder: refused before either clone\n'

if ansible-playbook -i localhost, tests/web/role.yml -e "web_container_user=$user" \
  -e 'web_contact_api_ref=0c856b9' -e 'web_smtp_host=mail.keepbreath.ing' \
  -e 'web_smtp_port=2587' -e 'web_smtp_user=contact@keepbreath.ing' \
  -e 'web_smtp_host_address=10.128.0.4' >"$work/missing-ref.log" 2>&1; then
  fail 'missing site ref was accepted'
fi
grep -F 'missing required arguments: web_site_ref' "$work/missing-ref.log" >/dev/null || fail 'missing site ref message differs'
printf 'PASS required site ref: argument validation fails\n'

if ansible-playbook -i localhost, tests/web/role.yml -e "web_container_user=$user" \
  -e 'web_site_ref=949b89f' -e 'web_contact_api_ref=0c856b9' \
  -e 'web_smtp_port=2587' -e 'web_smtp_user=contact@keepbreath.ing' \
  -e 'web_smtp_host_address=10.128.0.4' >"$work/missing-smtp-host.log" 2>&1; then
  fail 'missing SMTP host was accepted'
fi
grep -F 'missing required arguments: web_smtp_host' "$work/missing-smtp-host.log" >/dev/null || fail 'missing SMTP host message differs'
printf 'PASS required SMTP host: argument validation fails\n'

printf 'web driver: all cases passed\n'
