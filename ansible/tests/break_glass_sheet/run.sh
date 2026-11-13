#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
weed_name=b2glass-weed
host_name=s3.us-east-1.seaweedfs.test
if podman container exists "$weed_name"; then fail 'b2glass-weed container already exists'; fi
if grep -Eq '(^|[[:space:]])s3\.us-east-1\.seaweedfs\.test([[:space:]]|$)' /etc/hosts; then
  fail 's3.us-east-1.seaweedfs.test is already in /etc/hosts'
fi

source tests/lib/undo.sh
work=$(mktemp -d)
server=
base=http://127.0.0.1:18742
endpoint=http://s3.us-east-1.seaweedfs.test:8333
weed_image=docker.io/chrislusf/seaweedfs@sha256:57877e32bb90073b37dc109b438ba66e84fd5ed9ced5f5c04f56444ef243ce59
restic_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image"])')
aws_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["aws_cli_image"])')
export TEST_RESTIC_IMAGE="$restic_image"
export TEST_RESTIC_IMAGE_TAG=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image_tag"])')
export TEST_AWS_IMAGE="$aws_image"
export TEST_B2_API_URL="$base/b2api/v4/"
export TEST_B2_PASSWORD=test-b2-password
export TEST_HAS_PASSWORD=1
export TEST_BUCKET=b2glass-locked

undo_scratch() { rm -rf --one-file-system -- "$work"; }
undo_server() { if [[ -n $server ]] && kill -0 "$server" 2>/dev/null; then kill "$server"; fi; }
undo_weed() { if podman container exists "$weed_name"; then podman rm -f "$weed_name"; fi; }
undo_hosts() { cp -p -- "$work/hosts" /etc/hosts; }
undo_install
undo_add 'remove scratch folder' undo_scratch
python3 tests/b2_bucket/fake_b2.py >"$work/server.log" 2>&1 &
server=$!
undo_add 'stop fake B2 server' undo_server
for ((attempt=0; attempt<30; attempt++)); do
  if curl -fsS "$base/_state" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$base/_state" >/dev/null || fail 'fake B2 server must answer'
control() { curl -fsS -H 'Content-Type: application/json' -d "$1" "$base/_control" >/dev/null; }
state() { curl -fsS "$base/_state"; }
control '{"action":"s3_api_url","value":"http://s3.us-east-1.seaweedfs.test:8333"}'
control '{"action":"next_key","applicationKeyId":"test-key-glass","applicationKey":"test-glass-secret"}'
curl -fsS -u test-master-id:test-master-secret -H 'Content-Type: application/json' \
  -d '{"accountId":"test-account","bucketName":"b2glass-locked","bucketType":"allPrivate","fileLockEnabled":true}' \
  "$base/b2api/v4/b2_create_bucket" >"$work/fake-bucket.json"
cp -p -- /etc/hosts "$work/hosts"
undo_add 'restore /etc/hosts' undo_hosts
printf '127.0.0.1 %s\n' "$host_name" >>/etc/hosts

write_s3_config() {
  local secret=$1 actions=$2
  python3 - "$work/s3.json" "$secret" "$actions" <<'PY'
import json, sys
config = {"identities": [
    {"name": "driver", "credentials": [{"accessKey": "test-driver", "secretKey": "test-driver-secret"}],
     "actions": ["Admin", "Read", "List", "Write", "Tagging"]},
    {"name": "glass", "credentials": [{"accessKey": "test-key-glass", "secretKey": sys.argv[2]}],
     "actions": sys.argv[3].split(",")},
]}
with open(sys.argv[1], "w") as target:
    json.dump(config, target)
PY
}
write_s3_config test-glass-secret Read,List
podman run -d --name "$weed_name" --network host \
  -v "$work/s3.json:/etc/b2glass-s3.json:ro" \
  "$weed_image" mini -s3.config=/etc/b2glass-s3.json >"$work/weed-id"
undo_add 'remove SeaweedFS container' undo_weed
wait_weed() {
  for ((attempt=0; attempt<60; attempt++)); do
    if [[ $(curl -s -o /dev/null -w '%{http_code}' "$endpoint/") != 000 ]]; then return; fi
    sleep 1
  done
  fail 'SeaweedFS must answer'
}
wait_weed
restart_weed() {
  podman stop "$weed_name" >/dev/null
  write_s3_config "$1" "$2"
  podman start "$weed_name" >/dev/null
  wait_weed
}
aws() {
  podman run --rm --network host -e AWS_ACCESS_KEY_ID=test-driver -e AWS_SECRET_ACCESS_KEY=test-driver-secret \
    "$aws_image" --endpoint-url "$endpoint" --region us-east-1 s3api "$@"
}
aws create-bucket --bucket b2glass-locked --object-lock-enabled-for-bucket >"$work/bucket.json"
printf 'one restored file\n' >"$work/source"
setfattr -n security.selinux -v system_u:object_r:var_lib_t:s0 "$work/source" ||
  fail 'fixture must carry security.selinux'
printf 'second restored file\n' >"$work/second"
setfattr -n security.selinux -v system_u:object_r:var_lib_t:s0 "$work/second" ||
  fail 'second fixture must carry security.selinux'
seed_restic() {
  podman run --rm --network host -e AWS_ACCESS_KEY_ID=test-driver -e AWS_SECRET_ACCESS_KEY=test-driver-secret \
    -e RESTIC_PASSWORD=test-b2-password -v "$work/source:/source:ro" -v "$work/second:/second:ro" "$restic_image" \
    -r "s3:$endpoint/b2glass-locked/restic" "$@"
}
seed_restic init >"$work/restic-init.log"
seed_restic backup /source >"$work/restic-backup.log"
seed_restic backup /second >"$work/restic-backup-second.log"
curl -fsS -u test-master-id:test-master-secret -H 'Content-Type: application/json' \
  -d '{"accountId":"test-account","bucketName":"b2glass-empty","bucketType":"allPrivate","fileLockEnabled":true}' \
  "$base/b2api/v4/b2_create_bucket" >"$work/fake-bucket-empty.json"
podman run --rm --network host -e AWS_ACCESS_KEY_ID=test-driver -e AWS_SECRET_ACCESS_KEY=test-driver-secret \
  -e RESTIC_PASSWORD=test-b2-password "$restic_image" \
  -r "s3:$endpoint/b2glass-empty/restic" init >"$work/restic-init-empty.log"
curl -fsS -u test-master-id:test-master-secret -H 'Content-Type: application/json' \
  -d '{"accountId":"test-account","bucketName":"b2glass-hollow","bucketType":"allPrivate","fileLockEnabled":true}' \
  "$base/b2api/v4/b2_create_bucket" >"$work/fake-bucket-hollow.json"
mkdir "$work/tally"
printf 'last restored file\n' >"$work/zz-last"
hollow_restic() {
  podman run --rm --network host -e AWS_ACCESS_KEY_ID=test-driver -e AWS_SECRET_ACCESS_KEY=test-driver-secret \
    -e RESTIC_PASSWORD=test-b2-password -v "$work/source:/source:ro" -v "$work/tally:/tally:ro" \
    -v "$work/zz-last:/zz-last:ro" "$restic_image" -r "s3:$endpoint/b2glass-hollow/restic" "$@"
}
hollow_restic init >"$work/restic-hollow-init.log"
hollow_restic backup /source >"$work/restic-hollow-source.log"
hollow_restic backup /tally >"$work/restic-hollow-tally.log"
hollow_restic backup /zz-last >"$work/restic-hollow-zz-last.log"
mkdir "$work/unfiltered"
if podman run --rm --network host -e AWS_ACCESS_KEY_ID=test-driver \
  -e AWS_SECRET_ACCESS_KEY=test-driver-secret -e RESTIC_PASSWORD=test-b2-password \
  -v "$work/unfiltered:/restore:Z" "$restic_image" \
  -r "s3:$endpoint/b2glass-locked/restic" --no-lock restore latest --target /restore --verify \
  >"$work/unfiltered.log" 2>&1; then
  fail 'restore without the SELinux exclusion unexpectedly passed'
fi
grep -F 'security.selinux' "$work/unfiltered.log" ||
  fail 'restore without the SELinux exclusion did not report security.selinux'

play() {
  local case_name=$1
  shift
  ansible-playbook -i localhost, tests/break_glass_sheet/sheet.yml "$@" >"$work/$case_name.log" 2>&1
}
expect_failure() {
  local case_name=$1 expected=$2
  if play "$case_name"; then fail "$case_name unexpectedly passed"; fi
  grep -Fq "$expected" "$work/$case_name.log" ||
    { tail -30 "$work/$case_name.log"; fail "$case_name failure message"; }
}
no_temp() {
  if find /tmp -maxdepth 1 -name 'ansible.*break-glass-sheet' | grep -q .; then
    fail 'break-glass proof folder survived'
  fi
}
add_old_keys() {
  control '{"action":"add_key","key":{"applicationKeyId":"old-glass-1","applicationKey":"old-secret-1","keyName":"break-glass-sheet","capabilities":["listBuckets","listFiles","readFiles"],"bucketIds":["bucket-1"]}}'
  control '{"action":"add_key","key":{"applicationKeyId":"old-glass-2","applicationKey":"old-secret-2","keyName":"break-glass-sheet","capabilities":["listBuckets","listFiles","readFiles"],"bucketIds":["bucket-1"]}}'
}
clear_calls() { control '{"action":"clear_calls"}'; }
assert_calls() {
  state | python3 tests/break_glass_sheet/assertions.py "$1" || fail "$1 API state"
}
TEST_HAS_PASSWORD=0 expect_failure missing_password 'b2_copy_passwords has no b2 password for testhost'
assert_calls no_writes
printf 'PASS missing password refuses before key changes\n'
TEST_HAS_PASSWORD=1 TEST_BUCKET=b2glass-missing expect_failure missing_bucket 'B2 bucket b2glass-missing is missing; run playbooks/b2.yml first.'
assert_calls no_writes
printf 'PASS missing bucket refuses before key changes\n'
add_old_keys
control '{"action":"page_size","value":1}'
clear_calls
play check --check --diff || { tail -30 "$work/check.log"; fail 'check mode must pass'; }
grep -Eq 'localhost[[:space:]]+:.*changed=[1-9].*failed=0' "$work/check.log" || fail 'check mode recap'
grep -Fq 'B2 would create key break-glass-sheet' "$work/check.log" || fail 'check mode create report'
for id in old-glass-1 old-glass-2; do
  grep -Fq "B2 would delete key $id named break-glass-sheet" "$work/check.log" || fail "check mode delete report $id"
done
assert_calls no_writes
if grep -Eq 'old-secret-|test-b2-password' "$work/check.log"; then fail 'check mode printed a password'; fi
no_temp
printf 'PASS check mode reports rotation without changing keys\n'

clear_calls
sampler=
undo_sampler() { if [[ -n $sampler ]] && kill -0 "$sampler" 2>/dev/null; then kill "$sampler"; fi; }
python3 - "$work/cmdline-hits.txt" <<'PY' &
import glob, os, sys, time
hits_path = sys.argv[1]
secrets = (b"test-b2-password", b"test-glass-secret")
own = f"/proc/{os.getpid()}/cmdline"
seen = set()
while True:
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        if path == own:
            continue
        try:
            with open(path, "rb") as source:
                raw = source.read()
        except OSError:
            continue
        line = raw.removesuffix(b"\0").replace(b"\0", b" ")
        if line in seen or not any(secret in line for secret in secrets):
            continue
        seen.add(line)
        with open(hits_path, "ab") as hits:
            hits.write(line + b"\n")
    time.sleep(0.05)
PY
sampler=$!
undo_add 'stop command-line sampler' undo_sampler
play passing || { tail -35 "$work/passing.log"; fail 'passing role play'; }
sh -c 'sleep 1; true' test-b2-password
kill "$sampler" 2>/dev/null || true
wait "$sampler" || true
sampler=
control_line='sh -c sleep 1; true test-b2-password'
grep -Fxqs -- "$control_line" "$work/cmdline-hits.txt" || fail 'the command-line sampler missed its control'
leaked=$(grep -Fxv -- "$control_line" "$work/cmdline-hits.txt" | head -n 1) || true
[[ -z $leaked ]] || fail "a command line showed a sheet secret: $leaked"
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/passing.log" || fail 'passing recap'
assert_calls rotated
python3 tests/break_glass_sheet/assertions.py sheet <"$work/passing.log" || fail 'exact printed sheet'
no_temp
printf 'PASS scoped rotation, restore, upload refusal and exact sheet\n'

control '{"action":"remove_key","id":"test-key-glass"}'
failure_case() {
  local case_name=$1 phrase=$2 extra_capabilities=${3:-}
  control '{"action":"remove_key","id":"old-glass-1"}'
  control '{"action":"remove_key","id":"old-glass-2"}'
  add_old_keys
  if [[ -n $extra_capabilities ]]; then
    control "$(python3 -c 'import json, sys; print(json.dumps({"action": "next_key", "applicationKeyId": "test-key-glass", "applicationKey": "test-glass-secret", "extra_capabilities": [sys.argv[1]]}))' "$extra_capabilities")"
  else
    control '{"action":"next_key","applicationKeyId":"test-key-glass","applicationKey":"test-glass-secret"}'
  fi
  clear_calls
  expect_failure "$case_name" "$phrase"
  assert_calls rolled_back
  if grep -Eq 'test-glass-secret|wrong-repository-password|test-key-glass' "$work/$case_name.log"; then
    fail "$case_name printed a credential"
  fi
  if grep -Fq 'BREAK-GLASS SHEET' "$work/$case_name.log"; then fail "$case_name printed sheet"; fi
  no_temp
  printf 'PASS %s rolls back new key and keeps old keys\n' "$case_name"
}
restart_weed wrong-secret Read,List
failure_case bad_secret "Restore with the sheet's key failed for testhost. restic said: "
restart_weed test-glass-secret Read,List
TEST_B2_PASSWORD=wrong-repository-password failure_case bad_password "Restore with the sheet's key failed for testhost. restic said: "
grep -Fq 'wrong password or no key found' "$work/bad_password.log" || fail 'bad_password restic error'
TEST_B2_PASSWORD=test-b2-password
TEST_BUCKET=b2glass-empty failure_case empty_repository "The sheet's key found no snapshot in testhost's B2 repository"
TEST_BUCKET=b2glass-hollow failure_case hollow_set "Restore with the sheet's key failed for testhost. restic said: "
failure_case writable "B2 would accept uploads from the sheet's key for b2glass-locked. b2 said: HTTP 200" writeFiles
printf 'break-glass-sheet driver: all cases passed\n'
