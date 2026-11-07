#!/usr/bin/env bash
# Root driver for the hub_pull and hub_export roles (Backups B7a and B7b). It runs in CI and on the
# laptop's local runner: the backup server sits on a tmpfs instead of a loop device (Backups decision 67).
set -euo pipefail

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
for account in hptest kbtest hubexport; do
  if id -u "$account" >/dev/null 2>&1; then fail "$account already exists"; fi
done
units=(/home/hptest/.config/systemd/user/hub-pull-run@.service
  /etc/systemd/system/hub-pull@.service /etc/systemd/system/hub-pull@.timer)
for path in "${units[@]}" /etc/sudoers.d/hub-export /usr/local/libexec/hub-export \
  /etc/ssh/authorized_keys/hubexport /etc/ssh/sshd_config.d/12-hub-export.conf \
  /etc/ssh/sshd_config.d/11-authorized-keys.conf /etc/hub-export-test /root/.hub-export-test; do
  [[ ! -e $path ]] || fail 'hub pull files already exist'
done

source tests/lib/undo.sh
source tests/lib/runner.sh
work=$(mktemp -d)
point=$work/backup
manager_xdg=
hp_uid=
kb_uid=
ssh_units_started=()
redis_image=docker.io/library/redis:7-alpine@sha256:9702d01c1f10c3ea9f48211b4362e44f154ff02d063e6f7268eba804059f53bf
restic_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image"])')
export TEST_RESTIC_IMAGE=$restic_image TEST_MOUNT=$point
export TEST_LOGIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_RESTIC_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_BCRYPT=$(printf '%s\n' "$TEST_LOGIN_PASSWORD" | htpasswd -niB testweb | cut -d: -f2-)
export TEST_VERIFY_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_VERIFY_RESTIC_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_VERIFY_BCRYPT=$(printf '%s\n' "$TEST_VERIFY_PASSWORD" | htpasswd -niB verify | cut -d: -f2-)
redis_password=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
key=/home/hptest/.ssh/hub-pull
conf_dir=/home/hptest/.config/hub-pull
known_hosts=$conf_dir/known_hosts
ssh_options=(-T -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known_hosts")
# The tar cases: the tar kind's settings for the export play and testmail for the hub's pull.
tar_vars=(-e hub_export_test_vars=tar-export.yml -e @tests/hub_pull/testmail.yml)

as_user() {
  local account=$1 uid=$2
  shift 2
  (cd "$work" && HOME="/home/$account" USER="$account" LOGNAME="$account" \
    XDG_RUNTIME_DIR="/run/user/$uid" XDG_CONFIG_HOME="/home/$account/.config" \
    runuser -u "$account" -- "$@")
}
as_hp() { as_user hptest "$hp_uid" "$@"; }
as_kb() { as_user kbtest "$kb_uid" "$@"; }
restic_machine() {
  local machine=$1
  shift
  as_hp podman run --rm --network host --security-opt label=disable \
    --env-file "$conf_dir/$machine.env" "$restic_image" "$@"
}
snapshot_count() { restic_machine "$1" snapshots --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'; }
start_redis() {
  as_kb podman run -d --name keepbreath-redis -e "REDISCLI_AUTH=$redis_password" "$redis_image" \
    redis-server --requirepass "$1" >/dev/null
  for ((attempt=0; attempt<30; attempt++)); do
    if as_kb podman exec keepbreath-redis redis-cli ping 2>/dev/null | grep -qx PONG; then return 0; fi
    sleep 0.5
  done
  [[ $1 != "$redis_password" ]] || fail 'Redis must answer'
}
pull_play() {
  local log=$1
  shift
  ansible-playbook -i localhost, tests/hub_pull/pull.yml "$@" >"$log" 2>&1
}
require_recap() {
  grep -Eq "localhost[[:space:]]+:.*changed=$1 .*failed=0" "$2" || { tail -35 "$2" >&2; fail "$2 recap must report changed=$1 and failed=0"; }
}
assert_failure_message() {
  python3 - "$1" "$2" <<'PY' || fail 'play failure message must match exactly'
import json, pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
messages = [json.loads(match).get('msg') for match in re.findall(r'^fatal: \[localhost\]: FAILED! => (\{.*\})$', log, re.M)]
assert messages and messages[-1] == sys.argv[2], messages
PY
}
run_cursor() { journalctl --no-pager -n 1 --show-cursor -o cat | sed -n 's/^-- cursor: //p'; }
run_output() {
  journalctl --no-pager -o cat --after-cursor="$1" "_UID=$hp_uid" \
    "_SYSTEMD_USER_UNIT=hub-pull-run@$2.service" SYSLOG_IDENTIFIER=podman >"$3"
}
task_status() {
  python3 - "$1" "$2" <<'PY2'
import pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
header = re.compile(r'^TASK \[[^\]]*: ' + re.escape(sys.argv[2]) + r'\] \*+$')
starts = [index for index, line in enumerate(lines) if header.match(line)]
assert len(starts) == 1, starts
for line in lines[starts[0] + 1:]:
    match = re.match(r'^(ok|changed|skipping|fatal): \[localhost\]', line)
    if match:
        print(match.group(1))
        break
PY2
}
undo_scratch() { rm -rf --one-file-system -- "$work"; }
undo_mount() { if mountpoint -q "$point"; then umount "$point"; fi; }
undo_hptest() { runner_undo_account hptest; }
undo_kbtest() { runner_undo_account kbtest; }
undo_hubexport() { runner_undo_account hubexport; }
undo_export_files() {
  rm -f /etc/sudoers.d/hub-export /usr/local/libexec/hub-export \
    /etc/ssh/authorized_keys/hubexport /etc/ssh/sshd_config.d/12-hub-export.conf \
    /etc/ssh/sshd_config.d/11-authorized-keys.conf
  if systemctl is-active --quiet ssh.service; then systemctl reload ssh.service; fi
}
undo_ssh() {
  local unit
  # The socket first: stopping the service while its socket is active prints a warning.
  for unit in ssh.socket ssh.service; do
    if [[ " ${ssh_units_started[*]} " == *" $unit "* ]] && systemctl is-active --quiet "$unit"; then
      systemctl stop "$unit"
    fi
  done
}
undo_units() {
  local machine
  for machine in testweb testmail; do
    if systemctl is-enabled --quiet "hub-pull@$machine.timer"; then systemctl disable --now "hub-pull@$machine.timer" >/dev/null; fi
    if systemctl is-active --quiet "hub-pull@$machine.service"; then systemctl stop "hub-pull@$machine.service"; fi
    if systemctl is-failed --quiet "hub-pull@$machine.service"; then systemctl reset-failed "hub-pull@$machine.service"; fi
  done
  rm -f "${units[@]}"
  systemctl daemon-reload
}
undo_tar_etc() { rm -rf --one-file-system -- /etc/hub-export-test; }
undo_tar_root() { rm -rf --one-file-system -- /root/.hub-export-test; }

undo_install
undo_add 'remove scratch folder' undo_scratch
runner_save_environment
undo_add 'remove the export account' undo_hubexport
undo_add 'remove the export sudo rule and script' undo_export_files
undo_add 'remove kbtest account' undo_kbtest
undo_add 'remove hptest account' undo_hptest
mkdir -p "$point"
chmod 0755 "$work"
mount -t tmpfs -o size=256m tmpfs "$point"
undo_add 'unmount backup tmpfs' undo_mount
undo_add 'remove hub pull units' undo_units

# Case 1: missing lingering, before anything is written.
pull_play "$work/no-hptest.log" && fail 'hub pull without hptest must fail'
assert_failure_message "$work/no-hptest.log" 'Account lingering is required; run the backup_server role first.'
for unit in "${units[@]}"; do [[ ! -e $unit ]] || fail "unit written before lingering: $unit"; done
ansible-playbook -i localhost, tests/hub_pull/backup-server.yml >"$work/server.log" 2>&1 ||
  { tail -35 "$work/server.log" >&2; fail 'backup server role must pass'; }
hp_uid=$(id -u hptest)
pull_play "$work/no-kbtest.log" && fail 'hub export without kbtest must fail'
assert_failure_message "$work/no-kbtest.log" 'Hub export needs kbtest to exist and linger; run the baseline and site roles first.'
if id -u hubexport >/dev/null 2>&1; then fail 'hubexport made before kbtest lingered'; fi
useradd -m kbtest
kb_uid=$(id -u kbtest)
pull_play "$work/no-kbtest-linger.log" && fail 'hub export without kbtest lingering must fail'
assert_failure_message "$work/no-kbtest-linger.log" 'Hub export needs kbtest to exist and linger; run the baseline and site roles first.'
if id -u hubexport >/dev/null 2>&1; then fail 'hubexport made before kbtest lingered'; fi
# The key play runs before the export play by design, so case 1 leaves a key. Remove it so case 2
# starts from a host where nothing the playbook makes exists.
rm -f "$key" "$key.pub"
printf 'PASS missing lingering fails before changes\n'

loginctl enable-linger kbtest
systemctl start "user@$kb_uid.service" || {
  systemctl status "user@$kb_uid.service" --no-pager >&2 || :
  journalctl -u "user@$kb_uid.service" -n 20 --no-pager >&2 || :
  fail 'kbtest user manager must start'
}
start_redis "$redis_password"
as_kb podman exec keepbreath-redis redis-cli SET probe hello >/dev/null
as_kb podman exec keepbreath-redis redis-cli LPUSH celery task >/dev/null
# Starting ssh.service also starts ssh.socket on Ubuntu, so record both and stop whichever this
# driver started.
for unit in ssh.socket ssh.service; do
  if ! systemctl is-active --quiet "$unit"; then ssh_units_started+=("$unit"); fi
done
undo_add 'stop the ssh units the driver started' undo_ssh
systemctl start ssh.service

# Case 2: a fresh check-mode run plans every file and writes none.
pull_play "$work/check-first.log" --check --diff ||
  { tail -35 "$work/check-first.log" >&2; fail 'fresh check mode must pass'; }
require_recap '[0-9]+' "$work/check-first.log"
for path in "${units[@]}" "$key" "$conf_dir/testweb.conf" "$conf_dir/testweb.env" "$known_hosts"; do
  grep -Fq "Would write $path" "$work/check-first.log" || fail "check mode must plan $path"
  [[ ! -e $path ]] || fail "check mode wrote $path"
done
if id -u hubexport >/dev/null 2>&1; then fail 'check mode made hubexport'; fi
printf 'PASS fresh check mode plans every file without writing\n'

# The same fresh check with the tar kind, which defines no container setting.
pull_play "$work/check-first-tar.log" --check --diff "${tar_vars[@]}" ||
  { tail -35 "$work/check-first-tar.log" >&2; fail 'fresh check mode with the tar kind must pass'; }
require_recap '[0-9]+' "$work/check-first-tar.log"
grep -Fq 'Would write /etc/ssh/authorized_keys/hubexport' "$work/check-first-tar.log" ||
  fail 'tar check mode must plan the key entry'
for path in /usr/local/libexec/hub-export /etc/sudoers.d/hub-export; do
  [[ ! -e $path ]] || fail "tar check mode wrote $path"
done
printf 'PASS fresh check mode with the tar kind plans every file without writing\n'

# The files the tar export reads, made before case 3 so a run that stops there proves their removal.
mkdir /etc/hub-export-test
undo_add 'remove the tar test folder in /etc' undo_tar_etc
printf 'probe\n' >/etc/hub-export-test/main.cf
mkdir /root/.hub-export-test
undo_add 'remove the tar test folder in /root' undo_tar_root
printf 'token\n' >/root/.hub-export-test/token.ini
chmod 0600 /root/.hub-export-test/token.ini

# Case 3: the first real run installs everything and its verify tasks take one snapshot.
pull_play "$work/first.log" || { tail -35 "$work/first.log" >&2; fail 'first hub pull play must pass'; }
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/first.log" || fail 'first play recap failed'
id -u hubexport >/dev/null || fail 'hubexport must exist'
! grep -q '^hubexport:' /etc/subuid || fail 'hubexport must have no subordinate IDs'
mapfile -t entries </etc/ssh/authorized_keys/hubexport
[[ ${#entries[@]} -eq 1 ]] || fail 'authorized_keys must hold exactly one line'
[[ $(stat -c '%U:%G %a' /etc/ssh/authorized_keys/hubexport) == 'root:root 644' ]] || fail 'authorized_keys owner or mode is wrong'
sshd_keys=$(sshd -T -C user=hubexport,host=localhost,addr=127.0.0.1 | grep '^authorizedkeysfile ')
[[ $sshd_keys == 'authorizedkeysfile /etc/ssh/authorized_keys/%u' ]] || fail "sshd must read the export key, got $sshd_keys"
[[ ${entries[0]} == 'from="127.0.0.1",restrict,command="sudo -n /usr/local/libexec/hub-export" '* ]] ||
  fail "authorized_keys entry has the wrong options: ${entries[0]}"
[[ ${entries[0]} == *" $(cat "$key.pub")" ]] || fail 'authorized_keys must end with the full hub key'
visudo -cf /etc/sudoers.d/hub-export >/dev/null || fail 'sudo rule must pass visudo'
[[ $(stat -c %a /etc/sudoers.d/hub-export) == 440 ]] || fail 'sudo rule must be mode 0440'
[[ $(systemctl show hub-pull@testweb.timer -p UnitFileState --value) == enabled ]] || fail 'timer must be enabled'
value=$(systemctl show hub-pull@testweb.timer -p TimersCalendar --value)
grep -Eq 'OnCalendar=\*-\*-\* 02:30:00 ; next_elapse=[A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} 02:30:00 ' <<<"$value" ||
  fail "timer calendar is wrong: $value"
[[ $(snapshot_count testweb) == 1 ]] || fail 'first run must leave exactly one snapshot'
restic_machine testweb snapshots --json | python3 -c '
import json, sys
snapshot = json.load(sys.stdin)[0]
assert snapshot["hostname"] == "testweb", snapshot
assert "/web-redis.rdb" in snapshot["paths"], snapshot' || fail 'snapshot must be host testweb with /web-redis.rdb'
restic_machine testweb dump latest /web-redis.rdb >"$work/dump.rdb"
[[ $(head -c 9 "$work/dump.rdb") == REDIS0012 ]] || fail 'snapshot must hold a Redis dump'
podman run --rm --security-opt label=disable --volume "$work/dump.rdb:/dump.rdb:ro" "$redis_image" \
  redis-check-rdb /dump.rdb >"$work/check-rdb.log" 2>&1 || fail 'redis-check-rdb must accept the dump'
grep -Fq '[info] 2 keys read' "$work/check-rdb.log" || fail 'the dump must hold the two keys'
printf 'PASS first play installs the pull and takes a snapshot of the queue\n'

if [[ ${TEST_FAIL_AFTER_HUB_PULL_ROLE:-} == 1 ]]; then
  if TEST_POST_RUN_FAILURE_ARMED=1 pull_play "$work/post-run-failure.log"; then fail 'deliberate post-role failure must fail'; fi
  tail -35 "$work/post-run-failure.log"
  grep -Fq 'Deliberate failure after hub pull' "$work/post-run-failure.log" || fail 'deliberate failure must follow role'
  fail 'deliberate failure after hub pull'
fi

# Case 4: a second run and a check-mode run change no file.
pull_play "$work/second.log" || { tail -35 "$work/second.log" >&2; fail 'second hub pull play must pass'; }
require_recap 0 "$work/second.log"
pull_play "$work/check-existing.log" --check --diff || fail 'existing check mode must pass'
require_recap 0 "$work/check-existing.log"
! grep -Fq 'Would write ' "$work/check-existing.log" || fail 'existing check mode planned a file'
printf 'PASS second play and check mode report no changes\n'

# Case 5: the hub's key gets only the export, whatever it asks for.
as_hp ssh "${ssh_options[@]}" hubexport@127.0.0.1 id >"$work/asked-id.out" 2>"$work/asked-id.err" || fail 'forced command must answer'
[[ $(head -c 9 "$work/asked-id.out") == REDIS0012 ]] || fail 'asking for id must return the export'
! grep -aq 'uid=' "$work/asked-id.out" || fail 'id must never run'
as_hp ssh "${ssh_options[@]/-T/-tt}" hubexport@127.0.0.1 /bin/sh -c id </dev/null >/dev/null 2>"$work/pty.err" || :
grep -Fq 'PTY allocation request failed on channel 0' "$work/pty.err" || fail 'a terminal request must be refused'
as_hp ssh "${ssh_options[@]}" -W 127.0.0.1:22 hubexport@127.0.0.1 </dev/null >/dev/null 2>"$work/forward.err" || :
grep -Fq 'channel 0: open failed: administratively prohibited' "$work/forward.err" || fail 'a stdio forward must be refused'
other=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n $other ]] || fail 'the runner must have a non-loopback address'
set +e
as_hp ssh -T -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "hubexport@$other" >/dev/null 2>"$work/other.err"
ssh_rc=$?
set -e
[[ $ssh_rc == 255 ]] || fail "another address must exit 255, got $ssh_rc"
grep -Fq 'Permission denied (publickey' "$work/other.err" || fail 'another address must get Permission denied'
printf 'PASS the hub key gets only the export\n'

# Case 6: the sudo rule allows only the bare script.
for attempt in '/usr/local/libexec/hub-export x' '/bin/sh -c id' '-u kbtest /usr/local/libexec/hub-export'; do
  set +e
  # shellcheck disable=SC2086
  runuser -u hubexport -- sudo -n $attempt >/dev/null 2>"$work/sudo.err"
  sudo_rc=$?
  set -e
  [[ $sudo_rc == 1 ]] || fail "sudo must refuse with exit 1: $attempt, got $sudo_rc"
  grep -Fq 'sudo: a password is required' "$work/sudo.err" || fail "sudo must ask for a password: $attempt"
done
runuser -u hubexport -- sudo -n /usr/local/libexec/hub-export >"$work/bare.out" || fail 'the bare script must run'
[[ $(head -c 9 "$work/bare.out") == REDIS0012 ]] || fail 'the bare script must write the export'
printf 'PASS the sudo rule allows only the bare script\n'

# Case 7: a stopped container fails the pull without a snapshot or a retry.
count=$(snapshot_count testweb)
as_kb podman stop keepbreath-redis >/dev/null
cursor=$(run_cursor)
if systemctl start hub-pull@testweb.service; then fail 'a stopped container must fail the pull'; fi
run_output "$cursor" testweb "$work/stopped.log"
grep -Fq 'command failed: exit status' "$work/stopped.log" || fail 'restic must report the failed export'
[[ $(snapshot_count testweb) == "$count" ]] || fail 'a failed export must leave no snapshot'
[[ $(as_hp systemctl --user show hub-pull-run@testweb.service -p NRestarts --value) == 0 ]] || fail 'the pull must not restart'
as_kb podman rm keepbreath-redis >/dev/null
start_redis "$redis_password"
printf 'PASS a stopped container fails without a snapshot or retry\n'

# Case 8: a wrong host key fails before login.
cp -p -- "$known_hosts" "$work/known_hosts"
ssh-keygen -q -t ed25519 -N '' -f "$work/other_host" <<<y >/dev/null
printf '127.0.0.1 %s\n' "$(cut -d' ' -f1,2 "$work/other_host.pub")" >"$known_hosts"
count=$(snapshot_count testweb)
cursor=$(run_cursor)
if systemctl start hub-pull@testweb.service; then fail 'a wrong host key must fail the pull'; fi
run_output "$cursor" testweb "$work/hostkey.log"
grep -Fq 'Host key verification failed.' "$work/hostkey.log" || fail 'ssh must refuse the wrong host key'
[[ $(snapshot_count testweb) == "$count" ]] || fail 'a wrong host key must leave no snapshot'
cp -p -- "$work/known_hosts" "$known_hosts"
printf 'PASS a wrong host key fails before login\n'

# An unknown host must also fail. This catches accept-new, which refuses only changed keys.
: >"$known_hosts"
count=$(snapshot_count testweb)
cursor=$(run_cursor)
if systemctl start hub-pull@testweb.service; then fail 'an unknown host key must fail the pull'; fi
run_output "$cursor" testweb "$work/unknown-host.log"
grep -Fq 'Host key verification failed.' "$work/unknown-host.log" || fail 'ssh must refuse an unknown host key'
[[ $(snapshot_count testweb) == "$count" ]] || fail 'an unknown host key must leave no snapshot'
cp -p -- "$work/known_hosts" "$known_hosts"
printf 'PASS an unknown host key fails before login\n'

# The access role's drop-in must leave the hub export account able to log in.
printf 'AuthorizedKeysFile /etc/ssh/authorized_keys/%%u\n' > /etc/ssh/sshd_config.d/11-authorized-keys.conf
sshd -t && systemctl reload ssh.service
count=$(snapshot_count testweb)
systemctl start hub-pull@testweb.service || fail 'the pull must work with the access drop-in'
[[ $(snapshot_count testweb) == $((count + 1)) ]] || fail 'the access drop-in pull must add one snapshot'
printf 'PASS the access drop-in keeps the pull working\n'

# Case 9: a wrong Redis password fails the pull.
as_kb podman rm -f keepbreath-redis >/dev/null
start_redis "$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
count=$(snapshot_count testweb)
cursor=$(run_cursor)
if systemctl start hub-pull@testweb.service; then fail 'a wrong Redis password must fail the pull'; fi
run_output "$cursor" testweb "$work/auth.log"
grep -Fq 'AUTH failed' "$work/auth.log" || fail 'redis-cli must report the failed AUTH'
[[ $(snapshot_count testweb) == "$count" ]] || fail 'a failed AUTH must leave no snapshot'
printf 'PASS a wrong Redis password fails without a snapshot\n'

# A tar export without paths fails before any change.
script_sum=$(sha256sum /usr/local/libexec/hub-export)
pull_play "$work/no-tar-paths.log" "${tar_vars[@]}" -e '{"hub_export_tar_paths": []}' &&
  fail 'a tar export without paths must fail'
assert_failure_message "$work/no-tar-paths.log" "Hub export of kind tar needs hub_export_tar_paths; set it in the droplet's host_vars."
[[ $(sha256sum /usr/local/libexec/hub-export) == "$script_sum" ]] || fail 'a tar export without paths changed the script'
printf 'PASS a tar export without paths fails before changes\n'

# A redis export without its container settings fails before any change.
pull_play "$work/no-container.log" -e hub_export_container= && fail 'a redis export without its container must fail'
assert_failure_message "$work/no-container.log" "Hub export of kind redis needs hub_export_container_user and hub_export_container; set them in the droplet's host_vars."
[[ $(sha256sum /usr/local/libexec/hub-export) == "$script_sum" ]] || fail 'a redis export without its container changed the script'
printf 'PASS a redis export without its container settings fails before changes\n'

# Switching the stand-in droplet to the tar kind: check mode reports it, the real run makes it.
sudo_sum=$(sha256sum /etc/sudoers.d/hub-export)
pull_play "$work/check-tar.log" --check "${tar_vars[@]}" ||
  { tail -35 "$work/check-tar.log" >&2; fail 'check mode with the tar kind must pass'; }
[[ $(task_status "$work/check-tar.log" 'Hub export | Write the export script') == changed ]] ||
  fail 'check mode must report the switch to the tar script'
[[ $(tail -n 1 /usr/local/libexec/hub-export) == *'redis-cli --rdb -' ]] || fail 'check mode rewrote the script'
pull_play "$work/tar.log" "${tar_vars[@]}" || { tail -35 "$work/tar.log" >&2; fail 'the tar run must pass'; }
require_recap '[0-9]+' "$work/tar.log"
last_line=$(tail -n 1 /usr/local/libexec/hub-export)
[[ $last_line == 'cd / && exec tar -cf - etc/hub-export-test root/.hub-export-test' ]] ||
  fail "the tar script's last line is wrong: $last_line"
[[ $(sha256sum /etc/sudoers.d/hub-export) == "$sudo_sum" ]] || fail 'the tar run changed the sudo rule'
pull_play "$work/check-tar-again.log" --check "${tar_vars[@]}" ||
  { tail -35 "$work/check-tar-again.log" >&2; fail 'check mode after the tar run must pass'; }
require_recap 0 "$work/check-tar-again.log"
printf 'PASS check mode reports the switch to the tar script, and the real run makes it\n'

# A pull of the tar export takes a snapshot of exactly its files.
count=$(snapshot_count testmail)
systemctl start hub-pull@testmail.service || fail 'the tar pull must pass'
[[ $(snapshot_count testmail) == $((count + 1)) ]] || fail 'the tar pull must add one snapshot'
restic_machine testmail snapshots --json | python3 -c '
import json, sys
snapshot = json.load(sys.stdin)[-1]
assert snapshot["hostname"] == "testmail", snapshot
assert snapshot["paths"] == ["/testmail-config.tar"], snapshot' || fail 'snapshot must be host testmail with /testmail-config.tar'
restic_machine testmail dump latest /testmail-config.tar >"$work/mail.tar"
members=$(tar -tf - <"$work/mail.tar")
expected_members=$'etc/hub-export-test/\netc/hub-export-test/main.cf\nroot/.hub-export-test/\nroot/.hub-export-test/token.ini'
[[ $members == "$expected_members" ]] || fail "the tar snapshot's members are wrong: $members"
[[ $(tar -xOf - etc/hub-export-test/main.cf <"$work/mail.tar") == probe ]] || fail 'the tar snapshot must hold main.cf intact'
for machine in testweb testmail; do
  [[ $(systemctl show "hub-pull@$machine.timer" -p UnitFileState --value) == enabled ]] ||
    fail "hub-pull@$machine.timer must be enabled"
done
printf 'PASS a pull of the tar export takes a snapshot of its files\n'

# A missing tar path fails the export, and with it the pull, with no snapshot or retry.
rm -rf --one-file-system -- /root/.hub-export-test
count=$(snapshot_count testmail)
cursor=$(run_cursor)
if systemctl start hub-pull@testmail.service; then fail 'a missing tar path must fail the pull'; fi
run_output "$cursor" testmail "$work/missing-path.log"
# restic prefixes each line its command writes to standard error with "subprocess ssh: ".
grep -Fxq 'subprocess ssh: tar: root/.hub-export-test: Cannot stat: No such file or directory' "$work/missing-path.log" ||
  { cat "$work/missing-path.log" >&2; fail 'tar must report the missing path'; }
[[ $(snapshot_count testmail) == "$count" ]] || fail 'a missing tar path must leave no snapshot'
[[ $(as_hp systemctl --user show hub-pull-run@testmail.service -p NRestarts --value) == 0 ]] || fail 'the tar pull must not restart'
printf 'PASS a missing tar path fails without a snapshot or retry\n'

printf 'hub_pull driver: all cases passed\n'
