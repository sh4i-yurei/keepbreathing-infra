#!/usr/bin/env bash
set -euo pipefail

work=$(mktemp -d)
base=http://127.0.0.1:18742
credential=/home/b2test/.config/b2/vaultserv.env
server=
created_account=false
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
cleanup() {
  [[ -z $server ]] || { kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; }
  if [[ $created_account == true ]]; then
    userdel -r b2test >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
id b2test >/dev/null 2>&1 && fail 'b2test already exists'
useradd -m b2test
created_account=true
export TEST_B2_API_URL="$base/b2api/v4/"
python3 tests/b2_bucket/fake_b2.py >"$work/server.log" 2>&1 &
server=$!
sleep 1
curl -fsS "$base/_state" >/dev/null || fail 'fake B2 server did not start'
control() { curl -fsS -H 'Content-Type: application/json' -d "$1" "$base/_control" >/dev/null; }
state() { curl -fsS "$base/_state"; }
assert_state() { state | python3 tests/b2_bucket/assertions.py "$1" || fail "$1 state"; }
reset() { control '{"action":"reset"}'; rm -rf /home/b2test/.config/b2; }
clear_calls() { control '{"action":"clear_calls"}'; }
run() {
  local name=$1
  shift
  ansible-playbook -i localhost, "tests/b2_bucket/$name.yml" "$@" >"$work/$name.log" 2>&1 || {
    tail -35 "$work/$name.log"
    fail "$name play must pass"
  }
  grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/$name.log" || fail "$name recap failed=0"
}
assert_check_recap() {
  grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/bucket.log" || fail 'check recap failed=0'
  if [[ $1 == changed ]]; then
    ! grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/bucket.log" || fail 'check recap must report change'
  else
    grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/bucket.log" || fail 'unchanged check recap changed=0'
  fi
}
expect_failure() {
  local name=$1 phrase=$2
  if ansible-playbook -i localhost, "tests/b2_bucket/$name.yml" >"$work/$name.log" 2>&1; then
    fail "$name unexpectedly passed"
  fi
  grep -Fq "$phrase" "$work/$name.log" || { tail -30 "$work/$name.log"; fail "$name missing failure text: $phrase"; }
}
key_id() { sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$credential"; }

expect_failure missing 'missing required arguments: b2_buckets'
grep -Fq "Validating arguments against arg spec 'main'" "$work/missing.log" || fail 'missing b2_buckets must fail at argument validation'
assert_state missing
printf 'PASS missing b2_buckets fails before API calls\n'

run bucket --check --diff
assert_state check
assert_check_recap changed
grep -Fq 'B2 would create bucket keepbreathing-vaultserv-backup' "$work/bucket.log" || fail 'check missing bucket creation message'
grep -Fq 'B2 would update bucket keepbreathing-vaultserv-backup settings' "$work/bucket.log" || fail 'check missing newly created bucket settings message'
grep -Fq 'B2 would create hub key vaultserv-hub-backup' "$work/bucket.log" || fail 'check missing hub key creation message'
printf 'PASS check mode leaves B2 and runner unchanged\n'

clear_calls
run bucket
assert_state first
! grep -Fq 'test-master-secret' "$work/bucket.log" || fail 'master secret appeared in play output'
! grep -Fq 'test-hub-secret-' "$work/bucket.log" || fail 'hub secret appeared in play output'
python3 - <<'PY' || fail 'hub secret appeared outside credential file'
from pathlib import Path
credential = Path('/home/b2test/.config/b2/vaultserv.env')
secret = next(line.partition('=')[2] for line in credential.read_text().splitlines()
              if line.startswith('AWS_SECRET_ACCESS_KEY='))
matches = [path for path in Path('/home/b2test').rglob('*')
           if path.is_file() and secret in path.read_text(errors='replace')]
assert matches == [credential], matches
PY
printf 'PASS first bucket, key, credential and verify cycle\n'

clear_calls
run bucket
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/bucket.log" || {
  grep -B 1 '^changed:' "$work/bucket.log" || true
  fail 'second run changed=0'
}
assert_state idempotent
printf 'PASS second run changed=0\n'

clear_calls
run bucket --check --diff
assert_check_recap unchanged
! grep -Fq 'B2 would' "$work/bucket.log" || fail 'unchanged rehearsal reported an API write'
assert_state idempotent
printf 'PASS unchanged check mode reports changed=0\n'

control '{"action":"change_bucket","values":{"fileLockConfiguration":{"isClientAuthorizedToRead":true,"value":{"isFileLockEnabled":true,"defaultRetention":{"mode":"governance","period":{"duration":1,"unit":"days"}}}},"lifecycleRules":[]}}'
clear_calls
run bucket --check --diff
assert_check_recap changed
grep -Fq 'B2 would update bucket keepbreathing-vaultserv-backup settings' "$work/bucket.log" || fail 'check missing bucket update message'
assert_state check_drift
printf 'PASS bucket drift rehearsal reports update without writing\n'
run bucket

old=$(key_id)
before=$(sha256sum "$credential" | cut -d' ' -f1)
control "$(jq -nc --arg id "$old" '{action:"change_key",id:$id,values:{capabilities:["listBuckets","listFiles","readFiles","writeFiles","deleteFiles"]}}')"
clear_calls
run bucket --check --diff
assert_check_recap changed
grep -Fq "B2 would replace hub key $old" "$work/bucket.log" || fail 'check missing key replacement message'
[[ $(sha256sum "$credential" | cut -d' ' -f1) == "$before" ]] || fail 'check rewrote credential'
assert_state check_key_drift
printf 'PASS overpowered key rehearsal reports replacement without writing\n'
run bucket

control "$(jq -nc '{action:"add_key",key:{applicationKeyId:"test-check-orphan-id",applicationKey:"test-check-orphan-secret",bucketIds:["bucket-1"],capabilities:["listBuckets","listFiles","readFiles","writeFiles"],keyName:"vaultserv-hub-backup"}}')"
clear_calls
run bucket --check --diff
assert_check_recap changed
grep -Fq 'B2 would delete key test-check-orphan-id named vaultserv-hub-backup' "$work/bucket.log" || fail 'check missing orphan deletion message'
assert_state check_orphan
printf 'PASS orphan key rehearsal reports deletion without writing\n'
run bucket

control '{"action":"change_bucket","values":{"lifecycleRules":[{"daysFromHidingToDeleting":30,"daysFromStartingToCancelingUnfinishedLargeFiles":null,"daysFromUploadingToHiding":null,"fileNamePrefix":""}]}}'
clear_calls
run verify
run bucket
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/bucket.log" || fail 'real B2 rule next run changed=0'
assert_state idempotent
printf 'PASS real B2 lifecycle rule verifies and stays unchanged\n'

old=$(key_id)
control "$(jq -nc --arg id "$old" '{action:"remove_key",id:$id}')"
clear_calls
run bucket
assert_state new_key
printf 'PASS missing key replaced without delete\n'

old=$(key_id)
control "$(jq -nc --arg id "$old" '{action:"change_key",id:$id,values:{capabilities:["listBuckets","listFiles","readFiles","writeFiles","deleteFiles"]}}')"
clear_calls
run bucket
assert_state replaced_key
printf 'PASS overpowered key rotated\n'

old=$(key_id)
control "$(jq -nc --arg id "$old" '{action:"change_key",id:$id,values:{bucketIds:["bucket-1","bucket-2"]}}')"
clear_calls
run bucket
assert_state replaced_key
printf 'PASS cross-bucket key rotated\n'

control '{"action":"change_bucket","values":{"fileLockConfiguration":{"isClientAuthorizedToRead":true,"value":{"isFileLockEnabled":true,"defaultRetention":{"mode":"governance","period":{"duration":1,"unit":"days"}}}},"lifecycleRules":[]}}'
clear_calls
run bucket
assert_state drift
clear_calls
run bucket
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/bucket.log" || fail 'drift correction next run changed=0'
printf 'PASS bucket drift corrected and idempotent\n'

control '{"action":"change_bucket","values":{"lifecycleRules":[{"daysFromHidingToDeleting":30,"daysFromStartingToCancelingUnfinishedLargeFiles":7,"daysFromUploadingToHiding":null,"fileNamePrefix":""}]}}'
clear_calls
run bucket
assert_state drift
printf 'PASS unfinished large file lifecycle drift corrected\n'

control '{"action":"change_bucket","values":{"lifecycleRules":[{"daysFromHidingToDeleting":30,"daysFromStartingToCancelingUnfinishedLargeFiles":null,"daysFromUploadingToHiding":null,"fileNamePrefix":""},{"daysFromHidingToDeleting":1,"fileNamePrefix":"logs/"}]}}'
clear_calls
run bucket
assert_state drift
printf 'PASS extra lifecycle rule removed\n'

old=$(key_id)
before=$(sha256sum "$credential" | cut -d' ' -f1)
control "$(jq -nc --arg id "$old" '{action:"change_key",id:$id,values:{bucketId:"bucket-1"},remove:["bucketIds"]}')"
clear_calls
expect_failure bucket "has no bucketIds field"
grep -Fq "$old" "$work/bucket.log" || fail 'legacy field failure must name key ID'
[[ $(sha256sum "$credential" | cut -d' ' -f1) == "$before" ]] || fail 'legacy field failure changed credential'
assert_state legacy
printf 'PASS legacy bucketId fails without mutation\n'

control "$(jq -nc --arg id "$old" '{action:"change_key",id:$id,values:{bucketIds:["bucket-1"]},remove:["bucketId"]}')"
control '{"action":"add_key","key":{"applicationKeyId":"test-key-0000","applicationKey":"test-extra-secret","bucketIds":["bucket-1"],"capabilities":["listFiles"],"keyName":"other"}}'
control '{"action":"page_size","value":1}'
export TEST_B2_PAGE_SIZE=1
clear_calls
run bucket
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/bucket.log" || fail 'paged key run changed=0'
assert_state paged
unset TEST_B2_PAGE_SIZE
printf 'PASS paged key lookup\n'

reset
control '{"action":"duplicate_bucket"}'
clear_calls
expect_failure bucket duplicate_bucket_name
grep -Fq keepbreathing-vaultserv-backup "$work/bucket.log" || fail 'duplicate error must name bucket'
assert_state duplicate
printf 'PASS duplicate bucket refusal\n'

reset
run bucket
control '{"action":"allow_delete"}'
clear_calls
expect_failure verify 'delete-refusal check'
printf 'PASS verify catches delete permission regression\n'

reset
mkdir -p /home/b2test/.config
chown b2test:root /home/b2test/.config
chmod 0755 /home/b2test/.config
run bucket
assert_state config
printf 'PASS existing .config metadata preserved\n'

old=$(key_id)
rm "$credential"
clear_calls
run bucket
assert_state rebuilt
printf 'PASS rebuilt hub retires its old named key\n'

control "$(jq -nc '{action:"add_key",key:{applicationKeyId:"test-orphan-id",applicationKey:"test-orphan-secret",bucketIds:["bucket-1"],capabilities:["listBuckets","listFiles","readFiles","writeFiles"],keyName:"vaultserv-hub-backup"}}')"
clear_calls
run bucket
assert_state orphan
printf 'PASS interrupted rotation retires orphan key\n'

control "$(jq -nc '{action:"add_key",key:{applicationKeyId:"test-sheet-id",applicationKey:"test-sheet-secret",bucketIds:["bucket-1"],capabilities:["listBuckets","listFiles","readFiles"],keyName:"break-glass-sheet"}}')"
clear_calls
run bucket
assert_state sheet
printf 'PASS unrelated sheet key remains\n'

before=$(sha256sum "$credential" | cut -d' ' -f1)
chmod 0644 "$credential"
chown root:root "$credential"
clear_calls
run bucket
[[ $(sha256sum "$credential" | cut -d' ' -f1) == "$before" ]] || fail 'permission repair rewrote credential contents'
assert_state permissions
printf 'PASS credential metadata drift repaired without rewrite\n'

control '{"action":"seed_restic_versions","count":150}'
clear_calls
run verify
assert_state many_versions
printf 'PASS verify locates its name beyond 150 earlier versions\n'

printf 'PASS all B2 bucket role cases\n'
