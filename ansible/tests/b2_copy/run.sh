#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
if id -u bstest >/dev/null 2>&1; then fail 'bstest already exists'; fi
if [[ -e /etc/systemd/system/b2-copy@.timer || -e /etc/systemd/system/b2-copy@.service ]]; then
  fail 'b2-copy units already exist'
fi
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
bs_uid=
weed_name=b2-copy-weed
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
cred=/home/bstest/.config/b2/testhost.env
other_cred=/home/bstest/.config/b2/otherhost.env
hub_password=/home/bstest/.config/b2-copy/testhost/hub-password
b2_password=/home/bstest/.config/b2-copy/testhost/b2-password
run_unit=/home/bstest/.config/systemd/user/b2-copy-run@.service
timer=/etc/systemd/system/b2-copy@.timer
service=/etc/systemd/system/b2-copy@.service
repository=s3:http://s3.us-east-1.seaweedfs.test:8333/b2copy-locked/restic
other_repository=s3:http://s3.us-east-1.seaweedfs.test:8333/b2copy-locked/otherhost
no_record=/run/systemd/system/b2-copy@testhost.service.d

as_bs() {
  (cd "$work" && HOME=/home/bstest USER=bstest LOGNAME=bstest \
    XDG_RUNTIME_DIR="/run/user/$bs_uid" XDG_CONFIG_HOME=/home/bstest/.config \
    runuser -u bstest -- "$@")
}
restic_hub() {
  as_bs podman run --rm --network host --security-opt label=disable \
    --volume "$point/restic/testhost:/repo:rw" \
    --volume "$work/hub-password:/password:ro" "$restic_image" \
    --repo /repo --password-file /password "$@"
}
restic_b2() {
  as_bs podman run --rm --network host --security-opt label=disable \
    --env-file "$cred" --volume "$work/b2-password:/password:ro" "$restic_image" \
    --password-file /password "$@"
}
aws_cli() {
  as_bs podman run --rm --network host --env-file "$cred" \
    --volume "$work:$work:ro" \
    "$aws_image" --endpoint-url http://s3.us-east-1.seaweedfs.test:8333 \
    --region us-east-1 "$@"
}
aws() { aws_cli s3api "$@"; }
play() {
  local log=$1
  shift
  if ! ansible-playbook -i localhost, tests/b2_copy/copy.yml "$@" >"$log" 2>&1; then
    tail -35 "$log"
    as_bs systemctl --user status b2-copy-run@testhost.service --no-pager --full || :
    journalctl -u b2-copy@testhost.service -n 25 --no-pager || :
    fail 'b2_copy role play must pass'
  fi
  grep -Eq 'localhost[[:space:]]+:.*failed=0' "$log" || fail 'role play recap must report failed=0'
}
no_role_files() {
  [[ ! -e /home/bstest/.config/b2-copy && ! -e $timer && ! -e $service && ! -e $run_unit ]] ||
    fail 'preflight or check mode created role files'
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
undo_scratch() { rm -rf --one-file-system -- "$work"; }
undo_writer() { rm -f -- "$writer"; }
undo_no_record() {
  if [[ -e $no_record ]]; then
    rm -rf -- "$no_record"
    systemctl daemon-reload
  fi
}
undo_mount() { if mountpoint -q "$point"; then umount "$point"; fi; }
undo_bstest() { runner_undo_account bstest; }
undo_hosts() { cp -p -- "$work/hosts" /etc/hosts; }
undo_weed() { if podman container exists "$weed_name"; then podman rm -f "$weed_name"; fi; }
undo_listener() { if [[ -n \${listener:-} ]] && kill -0 "$listener" 2>/dev/null; then kill "$listener"; fi; }
undo_units() {
  for unit in b2-copy@testhost.timer b2-copy@otherhost.timer; do
    if systemctl is-enabled --quiet "$unit"; then systemctl disable --now "$unit"; fi
  done
  for unit in b2-copy@testhost.timer b2-copy@testhost.service b2-copy@otherhost.timer b2-copy@otherhost.service; do
    if systemctl is-active --quiet "$unit"; then systemctl stop "$unit"; fi
    if systemctl is-failed --quiet "$unit"; then systemctl reset-failed "$unit"; fi
  done
  rm -f "$timer" "$service"
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
undo_add 'remove bstest account' undo_bstest
ansible-playbook -i localhost, tests/b2_copy/backup-server.yml >"$work/server.log" 2>&1 ||
  { tail -35 "$work/server.log"; fail 'backup server role must pass'; }
bs_uid=$(id -u bstest)
undo_add 'remove B2 copy system units' undo_units
loginctl enable-linger bstest
systemctl start "user@$bs_uid.service"
install -d -o bstest -g bstest -m 0700 /home/bstest/.config/b2
printf '%s' "$TEST_HUB_PASSWORD" >"$work/hub-password"
printf '%s' "$TEST_B2_PASSWORD" >"$work/b2-password"
chown bstest:bstest "$work/hub-password" "$work/b2-password"
chmod 0600 "$work/hub-password" "$work/b2-password"
install -d -o bstest -g bstest -m 0700 "$point/restic/testhost"
restic_hub init >"$work/hub-init.log"
printf 'first snapshot\n' >"$work/source"
chown bstest:bstest "$work/source"
as_bs podman run --rm --network host --security-opt label=disable \
  --volume "$point/restic/testhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  --volume "$work/source:/source:ro" "$restic_image" \
  --repo /repo --password-file /password backup /source >"$work/hub-backup.log"
install -d -o bstest -g bstest -m 0700 "$point/restic/otherhost"
as_bs podman run --rm --network host --security-opt label=disable \
  --volume "$point/restic/otherhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  "$restic_image" --repo /repo --password-file /password init >"$work/other-init.log"
as_bs podman run --rm --network host --security-opt label=disable \
  --volume "$point/restic/otherhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  --volume "$work/source:/source:ro" "$restic_image" \
  --repo /repo --password-file /password backup /source >"$work/other-backup.log"

podman run -d --name "$weed_name" --network host \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  "$weed_image" mini >"$work/weed-id"
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
chown bstest:bstest "$cred"
chmod 0600 "$cred"
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nRESTIC_REPOSITORY=%s\n' \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$other_repository" >"$other_cred"
chown bstest:bstest "$other_cred"
chmod 0600 "$other_cred"
aws create-bucket --bucket b2copy-locked --object-lock-enabled-for-bucket >"$work/bucket.json"
aws put-object-lock-configuration --bucket b2copy-locked \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":1}}}'

if ansible-playbook -i localhost, tests/b2_copy/missing-password.yml >"$work/missing-password.log" 2>&1; then
  fail 'missing password must fail'
fi
grep -Fq 'b2_copy_passwords has no hub and b2 password for testhost' "$work/missing-password.log" ||
  { tail -30 "$work/missing-password.log"; fail 'missing password failure must be exact'; }
no_role_files
mv "$cred" "$work/credential"
if ansible-playbook -i localhost, tests/b2_copy/copy.yml >"$work/missing-credential.log" 2>&1; then
  fail 'missing credential must fail'
fi
grep -Fq 'B2 credentials for testhost are missing; run playbooks/b2.yml first.' "$work/missing-credential.log" ||
  { tail -30 "$work/missing-credential.log"; fail 'missing credential failure must be exact'; }
no_role_files
mv "$work/credential" "$cred"
if ansible-playbook -i localhost, tests/b2_copy/copy.yml >"$work/missing-writer.log" 2>&1; then
  fail 'missing writer must fail'
fi
grep -Fq "The backup success writer $writer is missing; apply node_exporter first." "$work/missing-writer.log" ||
  { tail -30 "$work/missing-writer.log"; fail 'missing writer failure must be exact'; }
no_role_files
install -d -o root -g root -m 0750 "$textfile"
undo_add 'remove backup success writer' undo_writer
ansible-playbook -i localhost, tests/b2_copy/backup-success.yml >"$work/writer.log" 2>&1 ||
  { tail -35 "$work/writer.log"; fail 'backup success writer play must pass'; }
printf 'PASS preflight refuses missing passwords and credentials before changes\n'

play "$work/check-fresh.log" --check --diff
grep -Eq 'localhost[[:space:]]+:.*changed=[1-9]' "$work/check-fresh.log" || fail 'fresh check mode must plan changes'
for file in "$hub_password" "$b2_password" "$timer" "$service" "$run_unit"; do
  grep -Fq "$file" "$work/check-fresh.log" || fail "check mode must name $file"
done
for machine in testhost otherhost; do
  grep -Fq "Would record the install time as the first success of copy $machine" "$work/check-fresh.log" ||
    fail "check mode must name the copy record for $machine"
done
no_role_files
[[ -z $(ls -A "$textfile") ]] || fail 'check mode must not write a record'
aws list-objects-v2 --bucket b2copy-locked --prefix restic/ >"$work/check-objects.json"
python3 - "$work/check-objects.json" <<'PY' || fail 'check mode must not create B2 repository'
import json, sys
assert not json.load(open(sys.argv[1])).get('Contents')
PY
printf 'PASS fresh check mode plans files without changing state\n'

play "$work/first.log"
for file in "$hub_password" "$b2_password"; do
  [[ $(stat -c '%a:%U' "$file") == 600:bstest ]] || fail "$file must be private to bstest"
done
[[ $(systemctl show b2-copy@testhost.timer -p UnitFileState --value) == enabled ]] || fail 'timer must be enabled'
[[ $(systemctl show b2-copy@testhost.timer -p ActiveState --value) == active ]] || fail 'timer must be active'
[[ $(systemctl show b2-copy@testhost.timer -p Persistent --value) == yes ]] || fail 'timer must be persistent'
systemctl show b2-copy@testhost.timer -p TimersCalendar --value | grep -Fq '03:30:00' || fail 'timer must run at 03:30'
restic_hub cat config >"$work/hub-config.json"
restic_b2 cat config >"$work/b2-config.json"
python3 - "$work/hub-config.json" "$work/b2-config.json" <<'PY' || fail 'chunker polynomial must match'
import json, sys
assert json.load(open(sys.argv[1]))['chunker_polynomial'] == json.load(open(sys.argv[2]))['chunker_polynomial']
PY
restic_hub snapshots --json >"$work/hub-snapshots.json"
restic_b2 snapshots --json >"$work/b2-snapshots.json"
python3 - "$work/hub-snapshots.json" "$work/b2-snapshots.json" <<'PY' || fail 'first hub snapshot must be copied exactly once'
import json, sys
hub = json.load(open(sys.argv[1]))
b2 = json.load(open(sys.argv[2]))
assert len(hub) == len(b2) == 1
assert [s['id'] for s in hub] == [s['original'] for s in b2]
PY
[[ $(ls -A "$textfile" | sort | paste -sd ' ') == 'backup-copy-otherhost.prom backup-copy-testhost.prom' ]] ||
  fail 'the first play must record exactly the copy of testhost and otherhost'
for machine in testhost otherhost; do
  time=$(read_time copy "$machine") || fail "the first play must record the copy of $machine"
  assert_record copy "$machine" "$time" 93600
done
printf 'PASS first role run copies snapshot and starts timer\n'
if [[ ${TEST_FAIL_AFTER_COPY_ROLE:-} == 1 ]]; then
  TEST_POST_RUN_FAILURE_ARMED=1 play "$work/post-run-failure.log"
  fail 'post-run failure injection did not fail'
fi

play "$work/check-existing.log" --check --diff
grep -Eq 'localhost[[:space:]]+:.*changed=0.*failed=0' "$work/check-existing.log" ||
  fail 'existing check mode must report changed=0 failed=0'
! grep -Fq 'Would record ' "$work/check-existing.log" || fail 'existing check mode must not plan a record'
play "$work/second.log"
grep -Eq 'localhost[[:space:]]+:.*changed=0.*failed=0' "$work/second.log" ||
  fail 'second run must report changed=0 failed=0'
restic_b2 snapshots --json >"$work/b2-second.json"
python3 - "$work/b2-second.json" <<'PY' || fail 'second run must keep one snapshot'
import json, sys
assert len(json.load(open(sys.argv[1]))) == 1
PY
printf 'PASS second role run and check mode are unchanged\n'

printf 'second snapshot\n' >"$work/source"
as_bs podman run --rm --network host --security-opt label=disable \
  --volume "$point/restic/testhost:/repo:rw" --volume "$work/hub-password:/password:ro" \
  --volume "$work/source:/source:ro" "$restic_image" \
  --repo /repo --password-file /password backup /source >"$work/hub-second.log"
test_before=$(read_time copy testhost)
other_before=$(read_time copy otherhost)
wait_past "$test_before"
systemctl start b2-copy@testhost.service || fail 'system service must copy second snapshot'
test_after=$(read_time copy testhost)
(( test_after > test_before )) || fail 'a successful copy of testhost must record a newer time'
assert_record copy testhost "$test_after" 93600
[[ $(read_time copy otherhost) == "$other_before" ]] || fail 'a copy of testhost must keep the copy record of otherhost'
[[ $(systemctl show b2-copy@testhost.service -p Result --value) == success ]] || fail 'system service must succeed'
restic_hub snapshots --json >"$work/hub-two.json"
restic_b2 snapshots --json >"$work/b2-two.json"
python3 - "$work/hub-two.json" "$work/b2-two.json" <<'PY' || fail 'system service must copy two originals'
import json, sys
hub = json.load(open(sys.argv[1]))
b2 = json.load(open(sys.argv[2]))
assert len(hub) == len(b2) == 2
assert sorted(s['id'] for s in hub) == sorted(s['original'] for s in b2)
PY
aws list-object-versions --bucket b2copy-locked --prefix restic/locks/ >"$work/locks.json"
python3 - "$work/locks.json" <<'PY' || fail 'each lock must have a kept version and latest delete marker'
import json, sys
data = json.load(open(sys.argv[1]))
versions = {v['Key'] for v in data.get('Versions', [])}
markers = {v['Key'] for v in data.get('DeleteMarkers', []) if v['IsLatest']}
assert versions and versions == markers
PY
wait_past "$other_before"
systemctl start b2-copy@otherhost.service || fail 'system service must copy otherhost'
other_after=$(read_time copy otherhost)
(( other_after > other_before )) || fail 'a successful copy of otherhost must record a newer time'
assert_record copy otherhost "$other_after" 93600
[[ $(read_time copy testhost) == "$test_after" ]] || fail 'a copy of otherhost must keep the copy record of testhost'
printf 'PASS system service copies second snapshot and hides locks\n'

undo_add 'remove no-record drop-in' undo_no_record
mkdir -p "$no_record"
printf '[Service]\nExecStartPost=\n' >"$no_record/no-record.conf"
systemctl daemon-reload
if ansible-playbook -i localhost, tests/b2_copy/copy.yml >"$work/no-record.log" 2>&1; then
  fail 'a copy that records no success must fail the verify'
fi
grep -Fq 'b2-copy@testhost.service ran without recording a new success for copy testhost.' "$work/no-record.log" ||
  { tail -30 "$work/no-record.log"; fail 'a copy that records no success must fail with the exact message'; }
undo_no_record
printf 'PASS the verify fails a copy that records no success\n'

mkdir "$work/fixtures"
for ((n=0; n<1001; n++)); do
  printf 'fixture\n' >"$work/fixtures/$(printf '0000%04d' "$n")"
done
aws_cli s3 cp "$work/fixtures" s3://b2copy-locked/restic/locks/ --recursive >"$work/fixture-upload.log"
for ((n=0; n<1001; n++)); do
  key=$(printf 'restic/locks/0000%04d' "$n")
  aws delete-object --bucket b2copy-locked --key "$key" >/dev/null
done
aws list-object-versions --bucket b2copy-locked --prefix restic/locks/0000 >"$work/fixture-versions.json"
python3 - "$work/fixture-versions.json" <<'PY' || fail 'pagination fixture must retain and hide exactly 1001 keys'
import json, sys
data = json.load(open(sys.argv[1]))
expected = {f'restic/locks/0000{n:04d}' for n in range(1001)}
versions = {entry['Key'] for entry in data.get('Versions', [])}
markers = {entry['Key'] for entry in data.get('DeleteMarkers', []) if entry['IsLatest']}
assert versions == markers == expected, (
    f'versions={len(versions)} markers={len(markers)} expected={len(expected)} '
    f'missing_versions={sorted(expected - versions)[:3]} '
    f'missing_markers={sorted(expected - markers)[:3]} '
    f'extra_versions={sorted(versions - expected)[:3]} '
    f'extra_markers={sorted(markers - expected)[:3]}'
)
PY
play "$work/paged.log"
printf 'PASS lock verification reads past the first 1000 entries\n'

aws create-bucket --bucket b2copy-plain >"$work/plain.json"
sed -i 's@b2copy-locked/restic@b2copy-plain/restic@' "$cred"
if ansible-playbook -i localhost, tests/b2_copy/copy.yml >"$work/plain.log" 2>&1; then
  fail 'unlocked bucket must fail lock verification'
fi
grep -Fq "B2 deleted the copy's lock file instead of hiding it" "$work/plain.log" ||
  fail 'plain bucket failure must name missing hidden lock'
sed -i 's@b2copy-plain/restic@b2copy-locked/restic@' "$cred"
printf 'PASS unlocked bucket fails the hidden-lock check\n'

test_before=$(read_time copy testhost)
other_before=$(read_time copy otherhost)
wait_past "$(( test_before > other_before ? test_before : other_before ))"
correct_password=$TEST_B2_PASSWORD
export TEST_B2_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
if ansible-playbook -i localhost, tests/b2_copy/copy.yml >"$work/wrong-password.log" 2>&1; then
  fail 'wrong B2 password must fail'
fi
grep -Fq 'wrong password or no key found' "$work/wrong-password.log" ||
  fail 'wrong B2 password must show restic error'
export TEST_B2_PASSWORD=$correct_password
[[ $(read_time copy testhost) == "$test_before" && $(read_time copy otherhost) == "$other_before" ]] ||
  fail 'a failed play must keep every recorded copy success'
restic_b2 snapshots --json >"$work/b2-after-wrong.json"
python3 - "$work/b2-after-wrong.json" <<'PY' || fail 'wrong password must preserve snapshots'
import json, sys
assert len(json.load(open(sys.argv[1]))) == 2
PY
printf 'PASS wrong password fails without changing B2 snapshots\n'

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
sed -i "s@:8333/b2copy-locked@:$listener_port/b2copy-locked@" "$cred"
test_before=$(read_time copy testhost)
wait_past "$test_before"
if systemctl start b2-copy@testhost.service; then fail 'hanging S3 run must time out'; fi
[[ $(read_time copy testhost) == "$test_before" ]] || fail 'a copy that times out must keep the recorded success'
[[ $(as_bs systemctl --user show b2-copy-run@testhost.service -p Result --value) == timeout ]] ||
  fail 'run unit must report timeout'
[[ $(systemctl show b2-copy@testhost.service -p Result --value) == exit-code ]] ||
  fail 'system service must report exit-code'
printf 'PASS hanging S3 run times out in the user unit\n'

printf 'PASS all B2 copy role cases\n'
