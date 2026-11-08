#!/usr/bin/env bash
# The openbao_backup driver: builds OpenBao with the openbao role, the backup server with the
# backup_server role and the openbao-snapshot consumer in the backup server's account with
# openbao_config, then runs the openbao_backup role against them through a stand-in for
# Tailscale's proxy (Backups decisions 72 to 74, Platform decision 9). It runs in CI and on the
# laptop's local runner, with the backup server on a tmpfs. Run as root from ansible/.
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
# ss lists every listening socket, including one that accepts connections and never answers.
listening() { [[ -n $(ss -ltnH "sport = :$1") ]]; }

# Refuse to start over anything this driver makes or removes, and leave it alone.
for account in bbbao bbtest; do
  if id -u "$account" >/dev/null 2>&1; then fail "$account already exists"; fi
done
for path in /etc/systemd/system/openbao-backup*; do
  if [[ -e $path || -L $path ]]; then fail 'openbao-backup units already exist under /etc/systemd/system'; fi
done
for port in 8200 8082 18300 18301 18302; do
  if listening "$port"; then fail "127.0.0.1:$port is already in use"; fi
done

work=$(mktemp -d)
point=$work/backup
undo_install
undo_work() { rm -rf --one-file-system -- "$work"; }
undo_add 'remove openbao_backup driver work' undo_work
runner_save_environment

mkdir -p "$point"
chmod 0755 "$work"
mount -t tmpfs -o size=256m tmpfs "$point"
undo_mount() { if mountpoint -q "$point"; then umount "$point"; fi; }
undo_add 'unmount backup tmpfs' undo_mount

# Account removal prints userdel's note about a missing mail spool; anything else is a failure.
remove_account() {
  local account=$1
  if ! runner_undo_account "$account" >"$work/cleanup-$account.txt" 2>&1; then
    cat "$work/cleanup-$account.txt" >&2
    return 1
  fi
  if grep -vFx "userdel: $account mail spool (/var/mail/$account) not found" "$work/cleanup-$account.txt" >"$work/cleanup-$account-unexpected.txt"; then
    cat "$work/cleanup-$account-unexpected.txt" >&2
    return 1
  fi
}
undo_bbbao() { remove_account bbbao; }
undo_bbtest() { remove_account bbtest; }
undo_add 'remove driver-created bbbao' undo_bbbao
undo_add 'remove driver-created bbtest' undo_bbtest

# The checks above proved no openbao-backup unit existed, so whatever is there now is the role's.
undo_units() {
  if systemctl is-enabled --quiet openbao-backup.timer 2>/dev/null; then
    systemctl disable --now openbao-backup.timer >/dev/null 2>&1
  fi
  if systemctl is-active --quiet openbao-backup.service; then systemctl stop openbao-backup.service; fi
  if systemctl is-failed --quiet openbao-backup.service; then systemctl reset-failed openbao-backup.service; fi
  rm -f /etc/systemd/system/openbao-backup.service /etc/systemd/system/openbao-backup.timer
  systemctl daemon-reload
}
undo_add 'remove openbao-backup units' undo_units

# A background process this driver started, stopped by its pid. Undo actions run in a subshell,
# which can't wait for it, so poll until it is gone.
stop_pid() {
  local pid=$1 label=$2 attempt
  [[ -n $pid ]] || return 0
  kill "$pid" 2>/dev/null || true
  for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  printf '%s %s is still running\n' "$label" "$pid" >&2
  return 1
}

proxy_pid=
start_proxy() {
  local address=$1 attempt
  python3 tests/openbao_client/proxy.py "$address" >"$work/proxy-$address.log" 2>&1 &
  proxy_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:18300/v1/sys/health || true) == 200 ]]; then
      return 0
    fi
    sleep 0.2
  done
  cat "$work/proxy-$address.log" >&2
  fail "the proxy stand-in must forward to OpenBao as $address"
}
stop_proxy() { stop_pid "$proxy_pid" 'proxy stand-in' && proxy_pid=; }
undo_add 'stop the proxy stand-in' stop_proxy

blackhole_pid=
start_blackhole() {
  local attempt
  python3 tests/openbao_backup/blackhole.py >"$work/blackhole.log" 2>&1 &
  blackhole_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    listening 18301 && return 0
    sleep 0.1
  done
  cat "$work/blackhole.log" >&2
  fail 'the silent listener must listen on 127.0.0.1:18301'
}
stop_blackhole() { stop_pid "$blackhole_pid" 'silent listener' && blackhole_pid=; }
undo_add 'stop the silent listener' stop_blackhole

# A root-owned folder that case 8 plants a link to, outside every home and outside $work, which
# bbtest can't enter.
plant=
undo_plant() { if [[ -n $plant ]]; then rm -rf --one-file-system -- "$plant"; fi; }
undo_add 'remove the planted folder' undo_plant

openbao_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["openbao_image"])')
restic_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image"])')
export TEST_OPENBAO_IMAGE=$openbao_image TEST_RESTIC_IMAGE=$restic_image TEST_MOUNT=$point
export TEST_SEAL_KEY TEST_ADMIN_PASSWORD TEST_ANSIBLE_PASSWORD
TEST_SEAL_KEY=$(python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())')
TEST_ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
TEST_ANSIBLE_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
export TEST_LOGIN_PASSWORD TEST_RESTIC_PASSWORD TEST_BCRYPT TEST_VERIFY_PASSWORD TEST_VERIFY_RESTIC_PASSWORD TEST_VERIFY_BCRYPT
TEST_LOGIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
TEST_RESTIC_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
TEST_BCRYPT=$(printf '%s\n' "$TEST_LOGIN_PASSWORD" | htpasswd -niB testhub | cut -d: -f2-)
TEST_VERIFY_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
TEST_VERIFY_RESTIC_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
TEST_VERIFY_BCRYPT=$(printf '%s\n' "$TEST_VERIFY_PASSWORD" | htpasswd -niB verify | cut -d: -f2-)

home=/home/bbtest
env_file=$home/.config/openbao-backup/restic.env
secret_id=$home/.config/openbao/approle/openbao-snapshot/secret-id
user_unit=$home/.config/systemd/user/openbao-backup-run.service
units=("$user_unit" /etc/systemd/system/openbao-backup.service /etc/systemd/system/openbao-backup.timer)
files=("$env_file" "$home/.config/openbao-backup/snapshot.sh" "${units[@]}")
start_task='OpenBao backup verify | Start the same system service as the timer'
folder_task="OpenBao backup | Make the account's openbao-backup folder"
bb_uid=

play_index=0
# Run a playbook from this folder; its log is $last_play_log and its exit status $play_status.
run_play() {
  local name=$1
  shift
  play_index=$((play_index + 1))
  last_play_log=$work/$name-$play_index.log
  play_status=0
  ansible-playbook -i localhost, "tests/openbao_backup/$name.yml" "$@" >"$last_play_log" 2>&1 || play_status=$?
}
# Run a playbook and require it to pass.
play() {
  local name=$1
  run_play "$@"
  if ((play_status != 0)); then
    tail -40 "$last_play_log"
    fail "$name play must pass"
  fi
}
# Run a playbook and require it to fail.
play_fails() {
  local label=$1
  shift
  run_play "$@"
  if ((play_status == 0)); then
    tail -40 "$last_play_log"
    fail "$label unexpectedly passed"
  fi
}
recap() {
  local log=$1 changed=$2 failed=$3
  grep -Eq "localhost[[:space:]]+:.* changed=$changed .* failed=$failed( |$)" "$log" || {
    tail -40 "$log"
    fail "$log recap must have changed=$changed and failed=$failed"
  }
}
# Require the play's last failure to be the named task, with a message holding every given text.
failed_at() {
  local log=$1 task=$2
  shift 2
  python3 - "$log" "$task" "$@" <<'PY' || { tail -40 "$log"; fail "the play must fail at: $task"; }
import pathlib, re, sys
log, task, texts = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2], sys.argv[3:]
current, failures = None, []
for line in log.splitlines():
    header = re.match(r'^TASK \[(?:[^\]:]*: )?(.*)\] \*+$', line)
    if header:
        current = header.group(1)
    elif line.startswith('fatal: [localhost]: FAILED! => '):
        failures.append((current, line))
assert failures, 'no task failed'
name, line = failures[-1]
assert name == task, (name, line)
for text in texts:
    assert text in line, (text, line)
PY
}

# Run a command as bbtest from /, with its run directory, the way its user manager would.
as_bb() {
  (cd / && HOME=$home USER=bbtest LOGNAME=bbtest XDG_RUNTIME_DIR="/run/user/$bb_uid" runuser -u bbtest -- "$@")
}
restic_bb() {
  as_bb podman run --rm --network host --security-opt label=disable --env-file "$env_file" "$restic_image" "$@"
}
snapshot_count() { restic_bb snapshots --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'; }
no_backup_container() {
  local label=$1
  as_bb podman ps -a --format json | python3 -c '
import json, sys
names = [name for container in json.load(sys.stdin) for name in container["Names"]]
sys.exit(1 if "openbao-backup" in names else 0)' || fail "$label must leave no openbao-backup container"
}
no_units() {
  local label=$1 unit
  for unit in "${units[@]}"; do [[ ! -e $unit ]] || fail "$label must not write $unit"; done
}
run_cursor() { journalctl --no-pager -n 1 --show-cursor -o cat | sed -n 's/^-- cursor: //p'; }
# Wait for a line holding the given text in bbtest's run unit journal since the cursor.
run_journal_has() {
  local cursor=$1 text=$2 attempt
  for ((attempt=0; attempt<30; attempt++)); do
    journalctl --no-pager -o cat --after-cursor="$cursor" "_UID=$bb_uid" \
      _SYSTEMD_USER_UNIT=openbao-backup-run.service >"$work/run-journal.log"
    grep -Fq -- "$text" "$work/run-journal.log" && return 0
    sleep 1
  done
  cat "$work/run-journal.log" >&2
  fail "bbtest's openbao-backup-run.service journal must hold: $text"
}

# OpenBao and the backup server, before the role.
play openbao
play backup-server
bb_uid=$(id -u bbtest)

# Case 1: check mode before openbao_config, so the consumer's AppRole files don't exist yet.
play role --check --diff
recap "$last_play_log" '[1-9][0-9]*' 0
for path in "${files[@]}"; do
  grep -Fq "Would write $path" "$last_play_log" || fail "check mode must report Would write $path"
  [[ ! -e $path ]] || fail "check mode wrote $path"
done
printf 'case 1: a fresh check-mode run reports its writes and writes nothing\n'

# Case 2: a real run at the same point stops before writing any unit.
play_fails 'a real run before openbao_config' role
failed_at "$last_play_log" 'OpenBao backup | Require the AppRole files' \
  'openbao_backup needs /home/bbtest/.config/openbao/approle/openbao-snapshot/role-id and secret-id; run openbao_config first'
no_units 'a real run before openbao_config'
printf 'case 2: a real run before openbao_config fails before writing a unit\n'

play config
start_proxy 192.0.2.10

# Case 3: the real run saves a snapshot through the proxy.
play role
recap "$last_play_log" '[0-9]+' 0
restic_bb snapshots --json >"$work/snapshots.json"
python3 - "$work/snapshots.json" <<'PY' || fail 'the first run must leave one snapshot of exactly /openbao.snap'
import json, sys
snapshots = json.load(open(sys.argv[1]))
assert len(snapshots) == 1, snapshots
assert snapshots[0]["paths"] == ["/openbao.snap"], snapshots
PY
restic_bb dump latest /openbao.snap >"$work/openbao.snap"
python3 - "$work/openbao.snap" <<'PY' || fail 'the snapshot must be a gzip tar of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed'
import sys, tarfile
with tarfile.open(sys.argv[1], mode="r:gz") as archive:
    names = sorted(archive.getnames())
assert names == sorted(["meta.json", "state.bin", "SHA256SUMS", "SHA256SUMS.sealed"]), names
PY
no_backup_container 'the first run'
[[ $(systemctl show openbao-backup.timer -p UnitFileState --value) == enabled ]] || fail 'openbao-backup.timer must be enabled'
next=$(systemctl show openbao-backup.timer -p NextElapseUSecRealtime --value)
[[ -n $next && $next != n/a ]] || fail "openbao-backup.timer must have a next elapse time, got '$next'"
printf 'case 3: the real run saves a snapshot through the proxy and leaves no container\n'

# Case 4: a second run changes nothing.
play role
recap "$last_play_log" 0 0
printf 'case 4: a second run reports changed=0\n'

# Case 5: a refused sign-in fails the job and saves nothing.
as_bb cat "$secret_id" >"$work/secret-id"
count=$(snapshot_count)
printf '%s' 00000000-0000-0000-0000-000000000000 | as_bb tee "$secret_id" >/dev/null
cursor=$(run_cursor)
if systemctl start openbao-backup.service; then fail 'a refused sign-in must fail openbao-backup.service'; fi
run_journal_has "$cursor" 'invalid role or secret ID'
[[ $(snapshot_count) == "$count" ]] || fail 'a refused sign-in must save no snapshot'
no_backup_container 'a refused sign-in'
as_bb tee "$secret_id" <"$work/secret-id" >/dev/null
printf 'case 5: a refused sign-in fails without a snapshot or a container\n'

# Case 6: an OpenBao that can't be reached fails after the bounded wait.
count=$(snapshot_count)
cursor=$(run_cursor)
play_fails 'an unreachable OpenBao' role -e openbao_backup_address=http://127.0.0.1:18302 -e openbao_backup_wait=10
failed_at "$last_play_log" "$start_task"
run_journal_has "$cursor" 'openbao-backup: OpenBao at http://127.0.0.1:18302 did not answer unsealed within 10 seconds'
[[ $(snapshot_count) == "$count" ]] || fail 'an unreachable OpenBao must save no snapshot'
no_backup_container 'an unreachable OpenBao'
play role
recap "$last_play_log" '[0-9]+' 0
printf 'case 6: an unreachable OpenBao fails after the wait, without a snapshot or a container\n'

# Case 7: an OpenBao that never answers hits the run unit's time limit, and the container goes.
start_blackhole
count=$(snapshot_count)
play_fails 'a run past its time limit' role -e openbao_backup_address=http://127.0.0.1:18301 \
  -e openbao_backup_timeout=20 -e openbao_backup_wait=300
failed_at "$last_play_log" "$start_task"
result=$(as_bb systemctl --user show openbao-backup-run.service -p Result --value)
[[ $result == timeout ]] || fail "openbao-backup-run.service must end with Result=timeout, got $result"
sleep 15
no_backup_container 'a run past its time limit'
[[ $(snapshot_count) == "$count" ]] || fail 'a run past its time limit must save no snapshot'
stop_blackhole
play role
recap "$last_play_log" '[0-9]+' 0
printf 'case 7: a run past its time limit ends with Result=timeout and leaves no container\n'

# Case 8: a link planted in place of the account's folder is not followed.
plant=$(mktemp -d /run/openbao-backup-plant.XXXXXX)
chmod 0755 "$plant"
printf 'root file\n' >"$plant/keep"
before=$(stat -c '%U:%G %a' "$plant"; ls -A "$plant")
as_bb rm -rf -- "$home/.config/openbao-backup"
as_bb ln -s "$plant" "$home/.config/openbao-backup"
play_fails 'a planted link' role
failed_at "$last_play_log" "$folder_task" 'Operation not permitted' "$plant"
after=$(stat -c '%U:%G %a' "$plant"; ls -A "$plant")
[[ $after == "$before" ]] || fail "the planted folder changed: before $before, after $after"
as_bb rm -- "$home/.config/openbao-backup"
play role
recap "$last_play_log" '[0-9]+' 0
printf 'case 8: a planted link fails the folder task and leaves its target as it was\n'

# Case 9: the openbao-snapshot AppRole in another account is refused before any change.
play_fails 'a wrong openbao-snapshot account' role \
  -e '{"openbao_approles": [{"name": "openbao-snapshot", "account": "bbbao", "extra_paths": [{"path": "sys/storage/raft/snapshot", "capabilities": ["read"]}]}]}'
failed_at "$last_play_log" 'OpenBao backup | Require the openbao-snapshot AppRole in the account' \
  "openbao_backup needs the openbao-snapshot AppRole's files in bbtest's home; set its account to bbtest in openbao_approles"
recap "$last_play_log" 0 1
printf 'case 9: a wrong openbao-snapshot account is refused with changed=0\n'

printf 'openbao_backup driver: all cases passed\n'
