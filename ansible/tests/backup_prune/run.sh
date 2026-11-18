#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
if id -u bptest >/dev/null 2>&1; then fail 'bptest already exists'; fi
units=(/home/bptest/.config/systemd/user/backup-prune-run@.service
  /home/bptest/.config/systemd/user/backup-check-run@.service
  /etc/systemd/system/backup-prune@.service /etc/systemd/system/backup-prune@.timer
  /etc/systemd/system/backup-check@.service /etc/systemd/system/backup-check@.timer)
for unit in "${units[@]}" /etc/systemd/system/b2-copy@.service /etc/systemd/system/b2-copy@.timer; do
  [[ ! -e $unit ]] || fail 'backup prune units already exist'
done
if grep -Eq '(^|[[:space:]])s3\.us-east-1\.seaweedfs\.test([[:space:]]|$)' /etc/hosts; then
  fail 's3.us-east-1.seaweedfs.test is already in /etc/hosts'
fi
writer=/usr/local/libexec/backup-success
if [[ -e $writer ]]; then fail "$writer already exists"; fi

source tests/lib/undo.sh
source tests/lib/runner.sh
work=$(mktemp -d)
point=$work/backup
textfile=$work/textfile
export TEST_TEXTFILE=$textfile
manager_xdg=
bp_uid=
weed_name=backup-prune-weed
restic_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image"])')
aws_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["aws_cli_image"])')
weed_image=docker.io/chrislusf/seaweedfs@sha256:57877e32bb90073b37dc109b438ba66e84fd5ed9ced5f5c04f56444ef243ce59
export TEST_RESTIC_IMAGE=$restic_image TEST_AWS_IMAGE=$aws_image TEST_MOUNT=$point
export TEST_HUB_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_B2_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export AWS_ACCESS_KEY_ID=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
export AWS_SECRET_ACCESS_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_BCRYPT=$(printf '%s\n' "$TEST_HUB_PASSWORD" | htpasswd -niB testhost | cut -d: -f2-)
export TEST_VERIFY_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_VERIFY_RESTIC_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
export TEST_VERIFY_BCRYPT=$(printf '%s\n' "$TEST_VERIFY_PASSWORD" | htpasswd -niB verify | cut -d: -f2-)
cred=/home/bptest/.config/b2/testhost.env
other_cred=/home/bptest/.config/b2/otherhost.env
password_dir=/home/bptest/.config/b2-copy/testhost
hub_password=$password_dir/hub-password
b2_password=$password_dir/b2-password
repository=s3:http://s3.us-east-1.seaweedfs.test:8333/b2prune-locked/restic
other_repository=s3:http://s3.us-east-1.seaweedfs.test:8333/b2prune-locked/otherhost
records=(prune-testhost check-testhost prune-otherhost check-otherhost)

as_bp() {
  (cd "$work" && HOME=/home/bptest USER=bptest LOGNAME=bptest \
    XDG_RUNTIME_DIR="/run/user/$bp_uid" XDG_CONFIG_HOME=/home/bptest/.config \
    runuser -u bptest -- "$@")
}
restic_hub() {
  as_bp podman run --rm --network host --security-opt label=disable \
    --volume "$point/restic/testhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
    "$restic_image" --repo /repo --password-file /password "$@"
}
restic_b2() {
  as_bp podman run --rm --network host --security-opt label=disable \
    --env-file "$cred" --volume "$work/b2-password:/password:ro" \
    "$restic_image" --password-file /password "$@"
}
aws() {
  as_bp podman run --rm --network host --env-file "$cred" "$aws_image" \
    --endpoint-url http://s3.us-east-1.seaweedfs.test:8333 --region us-east-1 s3api "$@"
}
prune_play() {
  local log=$1; shift
  ansible-playbook -i localhost, tests/backup_prune/prune.yml "$@" >"$log" 2>&1
}
assert_failure_message() {
  python3 - "$1" "$2" <<'PY' || fail 'play failure message must match exactly'
import json, pathlib, re, sys
output = pathlib.Path(sys.argv[1]).read_text()
messages = []
for match in re.finditer(r'=>\s*\{', output):
    try:
        result, _ = json.JSONDecoder().raw_decode(output[match.end() - 1:])
    except json.JSONDecodeError:
        continue
    messages.append(result.get('msg'))
assert sys.argv[2] in messages, messages
PY
}
require_recap() {
  grep -Eq "localhost[[:space:]]+:.*changed=$1.*failed=0" "$2" ||
    { tail -35 "$2" >&2; fail "recap must report changed=$1 failed=0"; }
}
snapshots() {
  restic_hub snapshots --json >"$work/hub-now.json"
  restic_b2 snapshots --json >"$work/b2-now.json"
}
assert_snapshot_ids() {
  python3 - "$work/hub-now.json" "$work/b2-now.json" "$work/initial.json" "$@" <<'PY' || fail 'repository snapshots differ from expected IDs'
import json, sys
hub, b2, initial = [json.load(open(path)) for path in sys.argv[1:4]]
wanted = {initial[index] for index in map(int, sys.argv[4:])}
assert {item['id'] for item in hub} == wanted
assert {item['original'] for item in b2} == wanted
PY
}
read_time() { "$writer" --read "$1" "$2"; }
wait_past() { while (( $(date +%s) <= $1 )); do sleep 0.1; done; }
assert_record() {
  local stage=$1 target=$2 time=$3 limit=$4 labels
  labels="stage=\"$stage\",target=\"$target\""
  printf '%s\n' \
    "# HELP backup_last_success_timestamp_seconds Unix time of the stage's last successful run." \
    '# TYPE backup_last_success_timestamp_seconds gauge' \
    "backup_last_success_timestamp_seconds{$labels} $time" \
    "# HELP backup_max_age_seconds Age after which the stage's last success counts as stale." \
    '# TYPE backup_max_age_seconds gauge' \
    "backup_max_age_seconds{$labels} $limit" >"$work/expected-record"
  cmp -s "$work/expected-record" "$textfile/backup-$stage-$target.prom" ||
    fail "the $stage record for $target must hold time $time and limit $limit"
}
read_records() {
  local record
  for record in "${records[@]}"; do
    times[$record]=$(read_time "${record%%-*}" "${record#*-}")
  done
}
# Waits past every recorded second, so a write after this point gives a newer time.
wait_past_records() {
  local record newest=0
  for record in "${records[@]}"; do
    (( ${times[$record]} > newest )) && newest=${times[$record]}
  done
  wait_past "$newest"
}
# Requires each record but the named ones to keep the time read before.
require_kept() {
  local record time
  for record in "${records[@]}"; do
    [[ " $* " == *" $record "* ]] && continue
    time=$(read_time "${record%%-*}" "${record#*-}")
    [[ $time == "${times[$record]}" ]] || fail "the ${record%%-*} record for ${record#*-} must keep its time"
  done
}
# Requires the named record to hold a newer time than the one read before, in the writer's format.
require_newer() {
  local record=$1 message=$2 time
  time=$(read_time "${record%%-*}" "${record#*-}")
  (( time > ${times[$record]} )) || fail "$message"
  assert_record "${record%%-*}" "${record#*-}" "$time" 612000
}
declare -A times
run_cursor() { journalctl --no-pager -n 1 --show-cursor -o cat | sed -n 's/^-- cursor: //p'; }
run_output() {
  journalctl --no-pager -o cat --after-cursor="$1" "_UID=$bp_uid" \
    "_SYSTEMD_USER_UNIT=$2" SYSLOG_IDENTIFIER=podman >"$3"
}
undo_scratch() { rm -rf --one-file-system -- "$work"; }
undo_writer() { rm -f -- "$writer"; }
undo_mount() { if mountpoint -q "$point"; then umount "$point"; fi; }
undo_bptest() { runner_undo_account bptest; }
undo_hosts() { cp -p -- "$work/hosts" /etc/hosts; }
undo_weed() { if podman container exists "$weed_name"; then podman rm -f "$weed_name"; fi; }
undo_listener() { if [[ -n ${listener:-} ]] && kill -0 "$listener" 2>/dev/null; then kill "$listener"; fi; }
undo_lock() {
  if [[ -n ${lock_container:-} ]] && as_bp podman container exists "$lock_container"; then
    as_bp podman unpause "$lock_container" >/dev/null 2>&1 || :
    as_bp podman wait "$lock_container" >/dev/null
    as_bp podman rm "$lock_container" >/dev/null
  fi
}
undo_units() {
  for unit in backup-prune@testhost.timer backup-check@testhost.timer b2-copy@testhost.timer \
      backup-prune@otherhost.timer backup-check@otherhost.timer b2-copy@otherhost.timer; do
    if systemctl is-enabled --quiet "$unit"; then systemctl disable --now "$unit" >/dev/null; fi
  done
  for unit in backup-prune@testhost.service backup-check@testhost.service b2-copy@testhost.service \
      backup-prune@otherhost.service backup-check@otherhost.service b2-copy@otherhost.service; do
    if systemctl is-active --quiet "$unit"; then systemctl stop "$unit"; fi
    if systemctl is-failed --quiet "$unit"; then systemctl reset-failed "$unit"; fi
  done
  rm -f "${units[@]}" /etc/systemd/system/b2-copy@.service /etc/systemd/system/b2-copy@.timer
  systemctl daemon-reload
}

undo_install
undo_add 'remove scratch folder' undo_scratch
runner_save_environment
mkdir -p "$point"
chmod 0755 "$work"
truncate -s 512M "$work/backup.img"
mkfs.xfs -f -q "$work/backup.img"
mount -o loop "$work/backup.img" "$point"
undo_add 'unmount backup image' undo_mount
undo_add 'remove bptest account' undo_bptest
ansible-playbook -i localhost, tests/backup_prune/backup-server.yml >"$work/server.log" 2>&1 ||
  { tail -35 "$work/server.log" >&2; fail 'backup server role must pass'; }
bp_uid=$(id -u bptest)
undo_add 'remove backup prune and copy units' undo_units
loginctl enable-linger bptest
systemctl start "user@$bp_uid.service"
install -d -o bptest -g bptest -m 0700 /home/bptest/.config/b2
printf '%s' "$TEST_HUB_PASSWORD" >"$work/hub-password"
printf '%s' "$TEST_B2_PASSWORD" >"$work/b2-password"
chown bptest:bptest "$work/hub-password" "$work/b2-password"
chmod 0600 "$work/hub-password" "$work/b2-password"

podman run -d --name "$weed_name" --network host \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY "$weed_image" mini >"$work/weed-id"
undo_add 'remove SeaweedFS container' undo_weed
for ((attempt=0; attempt<60; attempt++)); do
  if [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8333/) != 000 ]]; then break; fi
  sleep 1
done
[[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8333/) != 000 ]] ||
  fail 'SeaweedFS must answer'
cp -p -- /etc/hosts "$work/hosts"
undo_add 'restore /etc/hosts' undo_hosts
printf '127.0.0.1 s3.us-east-1.seaweedfs.test\n' >>/etc/hosts
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nRESTIC_REPOSITORY=%s\n' \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$repository" >"$cred"
chown bptest:bptest "$cred"
chmod 0600 "$cred"
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nRESTIC_REPOSITORY=%s\n' \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$other_repository" >"$other_cred"
chown bptest:bptest "$other_cred"
chmod 0600 "$other_cred"
aws create-bucket --bucket b2prune-locked --object-lock-enabled-for-bucket >"$work/bucket.json" 2>&1 ||
  { tail -20 "$work/bucket.json" >&2; fail 'locked bucket must be created'; }
aws put-object-lock-configuration --bucket b2prune-locked \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":1}}}' >"$work/lock-config.log"

install -d -o bptest -g bptest -m 0700 "$point/restic/testhost"
restic_hub init >"$work/hub-init.log"
mkdir "$work/source"
chown bptest:bptest "$work/source"
dd if=/dev/urandom of="$work/source/z" bs=1024 count=64 status=none
chown bptest:bptest "$work/source/z"
backup_at() {
  as_bp podman run --rm --network host --security-opt label=disable \
    --volume "$point/restic/testhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
    --volume "$work/source:/source:ro" "$restic_image" \
    --repo /repo --password-file /password backup --time "$1" /source >"$2"
}
backup_at '2026-09-30 01:00:00' "$work/s0.log"
dd if=/dev/urandom of="$work/source/a" bs=1048576 count=3 status=none
chown bptest:bptest "$work/source/a"
backup_at '2026-10-01 01:00:00' "$work/s1.log"
rm "$work/source/a"
dd if=/dev/urandom of="$work/source/b" bs=1048576 count=3 status=none
chown bptest:bptest "$work/source/b"
backup_at '2026-10-01 02:00:00' "$work/s2.log"
dd if=/dev/urandom of="$work/source/c" bs=1048576 count=1 status=none
chown bptest:bptest "$work/source/c"
backup_at '2026-10-02 01:00:00' "$work/s3.log"
install -d -o bptest -g bptest -m 0700 "$point/restic/otherhost"
as_bp podman run --rm --network host --security-opt label=disable \
  --volume "$point/restic/otherhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  "$restic_image" --repo /repo --password-file /password init >"$work/other-init.log"
as_bp podman run --rm --network host --security-opt label=disable \
  --volume "$point/restic/otherhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  --volume "$work/source:/source:ro" "$restic_image" \
  --repo /repo --password-file /password backup /source >"$work/other-backup.log"
install -d -o root -g root -m 0750 "$textfile"
undo_add 'remove backup success writer' undo_writer
ansible-playbook -i localhost, tests/backup_prune/backup-success.yml >"$work/writer.log" 2>&1 ||
  { tail -35 "$work/writer.log" >&2; fail 'backup success writer play must pass'; }
restic_hub snapshots --json >"$work/hub-initial.json"
python3 - "$work/hub-initial.json" "$work/initial.json" <<'PY' || fail 'fixture must have four ordered snapshots'
import json, sys
items = sorted(json.load(open(sys.argv[1])), key=lambda item: item['time'])
assert len(items) == 4
json.dump([item['id'] for item in items], open(sys.argv[2], 'w'))
PY
if ! ansible-playbook -i localhost, tests/backup_prune/copy.yml >"$work/copy.log" 2>&1; then
  tail -35 "$work/copy.log" >&2
  fail 'b2_copy fixture role must pass'
fi
snapshots
assert_snapshot_ids 0 1 2 3

for path in "$hub_password" "$b2_password" "$cred"; do
  mv "$path" "$work/missing-file"
  if prune_play "$work/missing.log"; then fail "missing $path must fail"; fi
  assert_failure_message "$work/missing.log" "Prune for testhost needs $path; run playbooks/b2-copy.yml first."
  for unit in "${units[@]}"; do [[ ! -e $unit ]] || fail 'preflight created a unit'; done
  mv "$work/missing-file" "$path"
done
mv "$writer" "$work/writer-aside"
if prune_play "$work/missing-writer.log"; then fail 'missing writer must fail'; fi
assert_failure_message "$work/missing-writer.log" "The backup success writer $writer is missing; apply node_exporter first."
for unit in "${units[@]}"; do [[ ! -e $unit ]] || fail 'the writer check created a unit'; done
mv "$work/writer-aside" "$writer"
printf 'PASS missing input files fail before unit changes\n'

prune_play "$work/check-first.log" --check --diff ||
  { tail -35 "$work/check-first.log" >&2; fail 'fresh check mode must pass'; }
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/check-first.log" || fail 'check mode recap failed'
for unit in "${units[@]}"; do
  grep -Fq "Would write $unit" "$work/check-first.log" || fail "check mode must name $unit"
  [[ ! -e $unit ]] || fail 'check mode wrote a unit'
done
for machine in testhost otherhost; do
  for stage in prune check; do
    grep -Fq "Would record the install time as the first success of $stage $machine" "$work/check-first.log" ||
      fail "check mode must name the $stage record for $machine"
  done
done
[[ $(ls -A "$textfile" | sort | paste -sd ' ') == 'backup-copy-otherhost.prom backup-copy-testhost.prom' ]] ||
  fail 'check mode must not write a record'
snapshots
assert_snapshot_ids 0 1 2 3
printf 'PASS fresh check mode plans six units without changing repositories\n'

first_start=$(date +%s)
prune_play "$work/first.log" ||
  { tail -35 "$work/first.log" >&2; fail 'first prune role play must pass'; }
first_end=$(date +%s)
mkdir "$work/records-first"
for record in "${records[@]}"; do
  time=$(read_time "${record%%-*}" "${record#*-}") || fail "the first play must record the ${record%%-*} of ${record#*-}"
  (( first_start <= time && time <= first_end )) ||
    fail "the ${record%%-*} record for ${record#*-} must hold the install time"
  assert_record "${record%%-*}" "${record#*-}" "$time" 612000
  cp -p "$textfile/backup-$record.prom" "$work/records-first/"
done
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/first.log" || fail 'first play recap failed'
for unit in "${units[@]}"; do [[ -f $unit ]] || fail "missing unit $unit"; done
for kind in prune check; do
  timer=backup-$kind@testhost.timer
  [[ $(systemctl show "$timer" -p UnitFileState --value) == enabled ]] || fail "$timer must be enabled"
  [[ $(systemctl show "$timer" -p ActiveState --value) == active ]] || fail "$timer must be active"
  [[ $(systemctl show "$timer" -p Persistent --value) == yes ]] || fail "$timer must be persistent"
  grep -Fxq "Unit=backup-$kind@%i.service" "/etc/systemd/system/backup-$kind@.timer" ||
    fail "$timer must start its matching service"
  value=$(systemctl show "$timer" -p TimersCalendar --value)
  if [[ $kind == prune ]]; then expected='Sun *-*-* 05:00:00'; else expected='Sun *-*-* 05:30:00'; fi
  [[ $(grep -o 'OnCalendar=' <<<"$value" | wc -l) -eq 1 ]] &&
    grep -Eq "OnCalendar=Sun \\*-\\*-\\* ${expected##* } ; next_elapse=Sun [0-9]{4}-[0-9]{2}-[0-9]{2} ${expected##* } " <<<"$value" ||
    fail "$timer calendar or next Sunday is wrong: $value"
done
snapshots
assert_snapshot_ids 0 1 2 3
printf 'PASS first play installs timers and leaves snapshots unchanged\n'

if [[ ${TEST_FAIL_AFTER_PRUNE_ROLE:-} == 1 ]]; then
  if TEST_POST_RUN_FAILURE_ARMED=1 prune_play "$work/post-run-failure.log"; then fail 'deliberate post-role failure must fail'; fi
  tail -35 "$work/post-run-failure.log"
  grep -Fq 'Deliberate failure after backup prune' "$work/post-run-failure.log" ||
    fail 'deliberate failure must follow role'
  fail 'deliberate failure after backup prune'
fi

wait_past "$first_end"
prune_play "$work/second.log" || fail 'second role play must pass'
require_recap 0 "$work/second.log"
for record in "${records[@]}"; do
  cmp -s "$work/records-first/backup-$record.prom" "$textfile/backup-$record.prom" ||
    fail "a second play must keep the ${record%%-*} record for ${record#*-}"
done
prune_play "$work/check-existing.log" --check --diff || fail 'existing check mode must pass'
require_recap 0 "$work/check-existing.log"
! grep -Fq 'Would write ' "$work/check-existing.log" || fail 'existing check mode planned a unit'
! grep -Fq 'Would record ' "$work/check-existing.log" || fail 'existing check mode planned a record'
printf 'PASS second play and check mode report no changes\n'

prune_play "$work/check-diff.log" --check --diff -e backup_prune_keep_daily=8 ||
  { tail -35 "$work/check-diff.log" >&2; fail 'changed keep count rehearsal must pass'; }
grep -Eq 'localhost[[:space:]]+:.*changed=[1-9][0-9]*.*failed=0' "$work/check-diff.log" ||
  fail 'changed keep count rehearsal must report a would-be change'
grep -Fq -- '--keep-daily 8' "$work/check-diff.log" ||
  fail 'changed keep count rehearsal must show the diff'
grep -Fq -- '--keep-daily 7' /home/bptest/.config/systemd/user/backup-prune-run@.service ||
  fail 'check mode must leave the installed prune unit unchanged'
printf 'PASS changed keep count rehearsal shows diff without writing units\n'

aws list-object-versions --bucket b2prune-locked --prefix restic/ >"$work/versions-before.json"
read_records
wait_past_records
cursor=$(run_cursor)
systemctl start backup-prune@testhost.service || fail 'prune system service must succeed'
require_newer prune-testhost 'a successful prune must record a newer time'
require_kept prune-testhost
run_output "$cursor" backup-prune-run@testhost.service "$work/prune-output.log"
[[ $(grep -Fc 'remove 1 snapshots:' "$work/prune-output.log") == 2 ]] ||
  fail 'prune must report removing one snapshot on each side'
[[ $(grep -Fc '1 snapshots have been removed, running prune' "$work/prune-output.log") == 2 ]] ||
  fail 'both repositories must run prune after forget'
[[ $(grep -c '^to delete:' "$work/prune-output.log") == 2 ]] ||
  fail 'both prunes must report data to delete'
snapshots
assert_snapshot_ids 0 2 3
for index in 0 2 3; do
  read -r hub_id b2_id < <(python3 - "$work/initial.json" "$work/b2-now.json" "$index" <<'PY'
import json, sys
hub_id = json.load(open(sys.argv[1]))[int(sys.argv[3])]
b2_id = next(item['id'] for item in json.load(open(sys.argv[2])) if item['original'] == hub_id)
print(hub_id, b2_id)
PY
)
  restic_hub ls "$hub_id" --json >"$work/hub-files-$index.jsonl"
  restic_b2 ls "$b2_id" --json >"$work/b2-files-$index.jsonl"
  python3 - "$work/hub-files-$index.jsonl" "$work/b2-files-$index.jsonl" "$index" <<'PY' || fail "retained snapshot $index must hold exact files on both sides"
import json, sys
expected = {0: {'/source/z'}, 2: {'/source/z', '/source/b'},
            3: {'/source/z', '/source/b', '/source/c'}}[int(sys.argv[3])]
for path in sys.argv[1:3]:
    files = {item['path'] for line in open(path) if (item := json.loads(line)).get('type') == 'file'}
    assert files == expected, (path, files, expected)
PY
done
restic_hub check --read-data >"$work/hub-check.log"
restic_b2 check --read-data >"$work/b2-check.log"
aws list-objects-v2 --bucket b2prune-locked --prefix restic/ >"$work/current-objects.json"
aws list-object-versions --bucket b2prune-locked --prefix restic/ >"$work/versions-after.json"
python3 - "$work/versions-before.json" "$work/versions-after.json" "$work/current-objects.json" <<'PY' || fail 'B2 prune must hide data and snapshot objects without deleting old versions'
import json, sys
before, after, current = [json.load(open(path)) for path in sys.argv[1:]]
old = {(v['Key'], v['VersionId']) for v in before.get('Versions', [])}
new = {(v['Key'], v['VersionId']) for v in after.get('Versions', [])}
assert old <= new, sorted(old - new)[:3]
old_keys = {key for key, _ in old}
current_keys = {v['Key'] for v in current.get('Contents', [])}
hidden = old_keys - current_keys
markers = {v['Key'] for v in after.get('DeleteMarkers', []) if v['IsLatest']}
assert hidden <= markers
assert any(key.startswith('restic/data/') for key in hidden)
assert any(key.startswith('restic/snapshots/') for key in hidden)
PY
printf 'PASS prune removes S1 on both sides and hides B2 objects\n'

read_records
wait_past_records
cursor=$(run_cursor)
systemctl start backup-check@testhost.service || fail 'check system service must succeed'
require_newer check-testhost 'a successful check must record a newer time'
require_kept check-testhost
run_output "$cursor" backup-check-run@testhost.service "$work/check-output.log"
[[ $(grep -Fc 'no errors were found' "$work/check-output.log") == 2 ]] ||
  fail 'check must report no errors on each side'
[[ $(grep -Fc 'read all data' "$work/check-output.log") == 2 ]] ||
  fail 'both checks must read all data'
printf 'PASS check reads every repository without errors\n'

read_records
wait_past_records
systemctl start backup-prune@otherhost.service || fail 'prune system service for otherhost must succeed'
require_newer prune-otherhost 'a successful prune of otherhost must record a newer time'
require_kept prune-otherhost
systemctl start backup-check@otherhost.service || fail 'check system service for otherhost must succeed'
require_newer check-otherhost 'a successful check of otherhost must record a newer time'
require_kept prune-otherhost check-otherhost
printf 'PASS each machine records only its own prune and check\n'

lock_container=backup-prune-held-lock
as_bp podman run -d --name "$lock_container" --network host --security-opt label=disable \
  --volume "$point/restic/testhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  "$restic_image" --repo /repo --password-file /password prune --dry-run >"$work/lock-container-id"
undo_add 'release held restic lock' undo_lock
for ((attempt=0; attempt<200; attempt++)); do
  if find "$point/restic/testhost/locks" -maxdepth 1 -type f -regextype posix-extended \
      -regex '.*/[0-9a-f]{64}' | grep -q .; then break; fi
  sleep 0.1
done
find "$point/restic/testhost/locks" -maxdepth 1 -type f -regextype posix-extended \
  -regex '.*/[0-9a-f]{64}' | grep -q . || fail 'exclusive lock must exist'
as_bp podman pause "$lock_container" >"$work/pause.log"
aws list-object-versions --bucket b2prune-locked --prefix restic/ >"$work/versions-before-lock.json"
read_records
wait_past_records
cursor=$(run_cursor)
lock_start=$SECONDS
if systemctl start backup-prune@testhost.service; then fail 'held lock must fail prune'; fi
[[ $(read_time prune testhost) == "${times[prune-testhost]}" ]] || fail 'a failed prune must keep the recorded success'
(( SECONDS - lock_start >= 5 )) || fail 'prune must wait at least five seconds for the lock'
run_output "$cursor" backup-prune-run@testhost.service "$work/locked-output.log"
grep -Fq 'repository is already locked exclusively' "$work/locked-output.log" ||
  fail 'held lock must appear in run unit output'
! grep -Fq 'Applying Policy:' "$work/locked-output.log" ||
  fail 'held hub lock must prevent B2 forget'
aws list-object-versions --bucket b2prune-locked --prefix restic/ >"$work/versions-after-lock.json"
cmp -s "$work/versions-before-lock.json" "$work/versions-after-lock.json" ||
  fail 'held hub lock changed B2 object versions'
undo_lock
lock_container=
snapshots
assert_snapshot_ids 0 2 3
printf 'PASS exclusive lock fails prune without changing snapshots\n'

cp "$hub_password" "$work/correct-hub-password"
printf 'wrong password\n' >"$hub_password"
chown bptest:bptest "$hub_password"
chmod 0600 "$hub_password"
if prune_play "$work/wrong-password-play.log"; then fail 'wrong password preview must fail'; fi
grep -Fq 'Read-only prune preview failed for testhost on the hub: ' "$work/wrong-password-play.log" ||
  fail 'preview must name hub failure'
grep -Fq 'wrong password or no key found' "$work/wrong-password-play.log" ||
  fail 'preview must show wrong password'
aws list-object-versions --bucket b2prune-locked --prefix restic/ >"$work/versions-before-wrong.json"
read_records
wait_past_records
cursor=$(run_cursor)
if systemctl start backup-prune@testhost.service; then fail 'wrong password system service must fail'; fi
[[ $(read_time prune testhost) == "${times[prune-testhost]}" ]] || fail 'a prune with a wrong password must keep the recorded success'
run_output "$cursor" backup-prune-run@testhost.service "$work/wrong-password-output.log"
grep -Fq 'wrong password or no key found' "$work/wrong-password-output.log" ||
  fail 'wrong password must appear in run unit output'
! grep -Fq 'Applying Policy:' "$work/wrong-password-output.log" ||
  fail 'wrong hub password must prevent B2 forget'
aws list-object-versions --bucket b2prune-locked --prefix restic/ >"$work/versions-after-wrong.json"
cmp -s "$work/versions-before-wrong.json" "$work/versions-after-wrong.json" ||
  fail 'wrong hub password changed B2 object versions'
restic_b2 snapshots --json >"$work/b2-after-wrong.json"
python3 - "$work/b2-after-wrong.json" "$work/initial.json" <<'PY' || fail 'wrong hub password changed B2 snapshots'
import json, sys
actual, initial = [json.load(open(path)) for path in sys.argv[1:]]
assert {item['original'] for item in actual} == {initial[i] for i in (0, 2, 3)}
PY
cp "$work/correct-hub-password" "$hub_password"
chown bptest:bptest "$hub_password"
chmod 0600 "$hub_password"
printf 'PASS wrong hub password fails preview and service before B2\n'

python3 - "$work/listener-ready" <<'PY' &
import pathlib, socket, sys, time
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 0))
server.listen()
pathlib.Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
while True:
    connection, _ = server.accept()
    time.sleep(120)
    connection.close()
PY
listener=$!
undo_add 'stop hanging listener' undo_listener
for ((attempt=0; attempt<40; attempt++)); do [[ -s $work/listener-ready ]] && break; sleep 0.25; done
[[ -s $work/listener-ready ]] || fail 'hanging listener must start'
listener_port=$(<"$work/listener-ready")
sed -i "s@:8333/b2prune-locked@:$listener_port/b2prune-locked@" "$cred"
read_records
wait_past_records
if systemctl start backup-prune@testhost.service; then fail 'hanging B2 run must time out'; fi
[[ $(read_time prune testhost) == "${times[prune-testhost]}" ]] || fail 'a prune that times out must keep the recorded success'
[[ $(as_bp systemctl --user show backup-prune-run@testhost.service -p Result --value) == timeout ]] ||
  fail 'run unit must report timeout'
[[ $(systemctl show backup-prune@testhost.service -p Result --value) == exit-code ]] ||
  fail 'system service must report exit-code'
printf 'PASS hanging B2 endpoint times out in the user unit\n'

printf 'backup-prune driver: all cases passed\n'
