#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=bctest
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'bctest already exists'; fi
if id -u bcnone >/dev/null 2>&1; then fail 'bcnone already exists'; fi
if id -u bcother >/dev/null 2>&1; then fail 'bcother already exists'; fi
# A listener may answer with 404 or 403, so only connection failure means free.
if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8200/ || true) != 000 ]]; then
  fail '127.0.0.1:8200 is already in use'
fi

work=$(mktemp -d)
undo_add 'remove openbao_config driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_install
runner_save_environment
undo_add 'remove driver-created bctest' runner_remove_account
runner_remove_account() {
  if ! runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1; then
    cat "$work/account-cleanup.log" >&2
    return 1
  fi
  if grep -vFx 'userdel: bctest mail spool (/var/mail/bctest) not found' "$work/account-cleanup.log" >"$work/unexpected-cleanup.log"; then
    cat "$work/unexpected-cleanup.log" >&2
    return 1
  fi
}
# bcother is created only by the 3.2d cases, after the check above proved it didn't exist.
remove_bcother() {
  if ! runner_undo_account bcother >"$work/bcother-cleanup.log" 2>&1; then
    cat "$work/bcother-cleanup.log" >&2
    return 1
  fi
  if grep -vFx 'userdel: bcother mail spool (/var/mail/bcother) not found' "$work/bcother-cleanup.log" >"$work/unexpected-bcother-cleanup.log"; then
    cat "$work/unexpected-bcother-cleanup.log" >&2
    return 1
  fi
}

export TEST_SEAL_KEY TEST_ADMIN_PASSWORD TEST_ANSIBLE_PASSWORD
TEST_SEAL_KEY=$(python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())')
TEST_ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
TEST_ANSIBLE_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
play_index=0
printf '%s\n' '{"openbao_approles":[{"name":"testsvc","account":"bctest"},{"name":"othersvc","account":"bctest"}]}' >"$work/consumers.json"
printf '%s\n' '{"openbao_approles":[{"name":"restore-check","files":false},{"name":"openbao-snapshot","account":"bctest","extra_paths":[{"path":"sys/storage/raft/snapshot","capabilities":["read"]}]}]}' >"$work/restore-consumers.json"
restore_list=$work/restore-consumers.json

# Run a playbook from this folder and require it to pass.
play() {
  local name=$1 log
  shift
  play_index=$((play_index + 1))
  log=$work/$name-$play_index.log
  last_play_log=$log
  if ansible-playbook -i localhost, "tests/openbao_config/$name.yml" "$@" >"$log" 2>&1; then
    if [[ -n ${admin_token:-} && ( $name == role || $name == verify ) ]]; then
      no_ansible_tokens "$name play"
    fi
    if [[ ${reserved_check:-0} == 1 && $name == role ]]; then reserved_policies_intact "$name play"; fi
    return 0
  fi
  tail -40 "$log"
  fail "$name play must pass"
}
# Run a playbook from this folder and require it to fail with an exact message.
play_fails() {
  local label=$1 name=$2 message=$3 log
  shift 3
  play_index=$((play_index + 1))
  log=$work/$label-$play_index.log
  last_play_log=$log
  if ansible-playbook -i localhost, "tests/openbao_config/$name.yml" "$@" >"$log" 2>&1; then
    fail "$label unexpectedly passed"
  fi
  grep -Fq "\"msg\": \"$message\"" "$log" || { tail -30 "$log"; fail "$label failed with the wrong message"; }
  if [[ -n ${admin_token:-} && ( $name == role || $name == verify ) ]]; then
    no_ansible_tokens "$label play"
  fi
  if [[ ${reserved_check:-0} == 1 && $name == role ]]; then reserved_policies_intact "$label play"; fi
}
play_fails_contains() {
  local label=$1 name=$2 message=$3 log
  shift 3
  play_index=$((play_index + 1))
  log=$work/$label-$play_index.log
  last_play_log=$log
  if ansible-playbook -i localhost, "tests/openbao_config/$name.yml" "$@" >"$log" 2>&1; then
    fail "$label unexpectedly passed"
  fi
  grep -Fq "$message" "$log" || { tail -30 "$log"; fail "$label failed without the expected message"; }
  if [[ -n ${admin_token:-} && ( $name == role || $name == verify ) ]]; then
    no_ansible_tokens "$label play"
  fi
  if [[ ${reserved_check:-0} == 1 && $name == role ]]; then reserved_policies_intact "$label play"; fi
}
recap() {
  local log=$1 expected=$2
  grep -Eq "localhost[[:space:]]+:.*changed=$expected .*failed=0" "$log" || {
    grep -B1 -F 'changed: [localhost]' "$log" || true
    tail -60 "$log"
    fail "$log recap must have changed=$expected and failed=0"
  }
}
changed_task() {
  local log=$1 title=$2
  python3 - "$log" "$title" <<'PY' || fail "$title must report changed on localhost"
import pathlib, re, sys
log, title = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
assert re.search(r'TASK \[openbao_config : ' + re.escape(title) + r'\][^\n]*\nchanged: \[localhost\]', log)
PY
}
reports_both_mounts() {
  local log=$1
  recap "$log" 2
  grep -Fq '"msg": "openbao_config would enable secret/ as a version 2 key/value store"' "$log" || fail 'check mode must report the key/value store'
  grep -Fq '"msg": "openbao_config would enable approle/"' "$log" || fail 'check mode must report AppRole'
}
check_restore_report() {
  local log=$1 message
  for message in 'the policy restore-check' 'the AppRole restore-check' 'the policy openbao-snapshot' 'the AppRole openbao-snapshot' "restore-check's test secret"; do
    grep -Fq "openbao_config would write $message" "$log" || fail "check mode must report $message"
  done
  grep -Fq 'openbao_config would issue a secret ID for openbao-snapshot and write its files' "$log" || fail 'snapshot files must be reported'
  if grep -Fq 'openbao_config would issue a secret ID for restore-check and write its files' "$log"; then fail 'restore-check must have no files'; fi
}

# Call OpenBao's API with the forwarded test address. The token is passed by variable name,
# so its value stays out of every command line. Prints the status; the body is in $work/api.json.
api() {
  local method=$1 path=$2 token_name=${3:-} body=${4:-}
  API_METHOD=$method API_PATH=$path API_TOKEN=${token_name:+${!token_name}} API_BODY=$body API_ADDRESS=${api_address:-192.0.2.10} \
    python3 - "$work/api.json" <<'PY'
import os, sys, urllib.error, urllib.request
headers = {"X-Forwarded-For": os.environ["API_ADDRESS"]}
if os.environ["API_TOKEN"]:
    headers["X-Vault-Token"] = os.environ["API_TOKEN"]
data = os.environ["API_BODY"].encode() or None
if data:
    headers["Content-Type"] = "application/json"
request = urllib.request.Request("http://127.0.0.1:8200/v1/" + os.environ["API_PATH"],
                                 data=data, headers=headers, method=os.environ["API_METHOD"])
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        code, content = response.status, response.read()
except urllib.error.HTTPError as error:
    code, content = error.code, error.read()
with open(sys.argv[1], "wb") as stream:
    stream.write(content)
print(code)
PY
}
api_expect() {
  local expected=$1 what=$2 status
  shift 2
  status=$(api "$@")
  [[ $status == "$expected" ]] || { cat "$work/api.json" >&2; fail "$what must answer $expected, got $status"; }
}
# Sign in with userpass and store the token in the named variable.
login() {
  local who=$1 password_name=$2 token_name=$3 body
  body=$(PASSWORD_NAME=$password_name python3 -c 'import json,os; print(json.dumps({"password": os.environ[os.environ["PASSWORD_NAME"]]}))')
  api_expect 200 "$who login" POST "auth/userpass/login/$who" '' "$body"
  printf -v "$token_name" '%s' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$work/api.json")"
}
healthy() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    [[ $(api GET sys/health) == 200 ]] && return 0
    sleep 1
  done
  return 1
}
# The kv mount at secret/ as keepbreath0 sees it: absent, or its type and version.
secret_mount() {
  api_expect 200 'sys/mounts read' GET sys/mounts admin_token
  python3 - "$work/api.json" <<'PY'
import json, sys
mount = json.load(open(sys.argv[1]))["data"].get("secret/")
print("absent" if mount is None else mount["type"] + " " + str((mount.get("options") or {}).get("version")))
PY
}
approle_mount() {
  api_expect 200 'sys/auth read' GET sys/auth admin_token
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["data"].get("approle/"); print("absent" if m is None else m["type"])' "$work/api.json"
}
# The role and its verify revoke their tokens, so no ansible token may be left. The driver
# revokes its own ansible tokens before it counts.
no_ansible_tokens() {
  local label=$1
  ADMIN_TOKEN=$admin_token python3 - <<'PY' || fail "$label left an ansible token"
import json, os, urllib.request
def call(method, path, body=None):
    request = urllib.request.Request("http://127.0.0.1:8200/v1/" + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-Forwarded-For": "192.0.2.10", "X-Vault-Token": os.environ["ADMIN_TOKEN"],
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)
keys = call("LIST", "auth/token/accessors")["data"]["keys"]
names = [call("POST", "auth/token/lookup-accessor", {"accessor": key})["data"]["display_name"] for key in keys]
assert not ({"userpass-ansible", "approle"} & set(names)), names
PY
}
logs_clean() {
  python3 - "$work" <<'PY' || fail 'play logs must contain no generated secrets'
import os, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('*.log'):
    data = path.read_text()
    for name in ('TEST_SEAL_KEY', 'TEST_ADMIN_PASSWORD', 'TEST_ANSIBLE_PASSWORD'):
        assert os.environ[name] not in data, (path, name)
    for secret in pathlib.Path(sys.argv[1]).glob('*-id'):
        assert secret.read_text() not in data, (path, secret)
PY
}
# The reserved policies survive every 3.2d run, and the ansible policy keeps the text it had
# before any reserved-name case ran.
reserved_policies_intact() {
  local label=$1
  api_expect 200 "$label policy list" LIST sys/policies/acl admin_token
  python3 - "$work/api.json" <<'PY' || fail "$label must keep the policies ansible, default, keepbreath0 and root"
import json, sys
keys = set(json.load(open(sys.argv[1]))['data']['keys'])
assert {'ansible', 'default', 'keepbreath0', 'root'} <= keys, sorted(keys)
PY
  api_expect 200 "$label ansible policy read" GET sys/policies/acl/ansible admin_token
  python3 - "$work/ansible-policy.json" "$work/api.json" <<'PY' || fail "$label must leave the ansible policy text unchanged"
import json, sys
before, after = (json.load(open(path))['data']['policy'] for path in sys.argv[1:])
assert before == after
PY
}
# A consumer's AppRole settings, role ID, policy text, and folder and files as one JSON line.
# The role ID and file contents are hashed, so the line holds no credential.
consumer_state() {
  local name=$1
  api_expect 200 "$name AppRole state" GET "auth/approle/role/$name" admin_token
  cp "$work/api.json" "$work/state-approle.json"
  api_expect 200 "$name role ID state" GET "auth/approle/role/$name/role-id" admin_token
  cp "$work/api.json" "$work/state-role.json"
  api_expect 200 "$name policy state" GET "sys/policies/acl/$name" admin_token
  python3 - "$work/state-approle.json" "$work/state-role.json" "$work/api.json" "$name" <<'PY'
import hashlib, json, pathlib, sys
approle, role, policy = (json.load(open(path))['data'] for path in sys.argv[1:4])
folder = pathlib.Path('/home/bctest/.config/openbao/approle') / sys.argv[4]
def stat(path):
    info = path.stat()
    return [oct(info.st_mode), info.st_uid, info.st_gid, info.st_ino]
files = {path.name: stat(path) + [hashlib.sha256(path.read_bytes()).hexdigest()]
         for path in sorted(folder.iterdir())}
print(json.dumps({'approle': approle, 'role_id': hashlib.sha256(role['role_id'].encode()).hexdigest(),
                  'policy': policy['policy'], 'folder': stat(folder), 'files': files}, sort_keys=True))
PY
}
# The folder removal task reports this folder as changed, in its own section of the log.
removed_folder() {
  local log=$1 folder=$2
  python3 - "$log" "$folder" <<'PY' || fail "the folder task must report $folder as changed"
import pathlib, re, sys
log, folder = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
match = re.search(r'TASK \[openbao_config : OpenBao config \| Remove consumer folders that belong to no entry with files\][^\n]*\n(.*?)(?=\nTASK \[|\nPLAY RECAP)', log, re.S)
assert match, 'no folder removal task'
assert 'changed: [localhost] => (item=' + folder + ')' in match.group(1), match.group(1)
PY
}
# The role warns that it skipped this folder, naming it as a JSON string, for this reason.
skipped_warning() {
  local log=$1 folder=$2 reason=$3
  python3 - "$log" "$folder" "$reason" <<'PY' || fail "the role must warn that it skipped ${folder@Q}, $reason"
import json, pathlib, re, sys
log, folder, reason = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2], sys.argv[3]
messages = [json.loads(text) for text in re.findall(r'"msg": ("(?:[^"\\]|\\.)*")', log)]
assert 'openbao_config warning: skipped ' + json.dumps(folder) + ', ' + reason in messages, messages
PY
}
# Whether the play log holds this exact message, reading each msg as a JSON string.
has_message() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, re, sys
log, message = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
messages = [json.loads(text) for text in re.findall(r'"msg": ("(?:[^"\\]|\\.)*")', log)]
sys.exit(0 if message in messages else 1)
PY
}
reports() { has_message "$1" "$2" || fail "the role must report: $2"; }
reports_not() { if has_message "$1" "$2"; then fail "the role must not report: $2"; fi; }
# The role warns that a listed transit key is missing, naming decision 27's restore and the flag.
transit_warning_text() {
  printf '%s' "openbao_config warning: transit key $1 is missing; restore OpenBao's snapshot (decision 27), or make it on purpose with -e openbao_make_transit_keys=true"
}
transit_warning() { reports "$1" "$(transit_warning_text "$2")"; }
no_transit_warning() { reports_not "$1" "$(transit_warning_text "$2")"; }
# transit/ as keepbreath0 sees it: absent, or its type.
transit_mount() {
  api_expect 200 'sys/mounts read' GET sys/mounts admin_token
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["data"].get("transit/"); print("absent" if m is None else m["type"])' "$work/api.json"
}
# A transit key as keepbreath0 reads it: its type and its deletion, export and plaintext backup
# settings, or the status when the read isn't 200.
key_state() {
  local status
  status=$(api GET "transit/keys/$1" admin_token)
  if [[ $status != 200 ]]; then printf '%s\n' "$status"; return 0; fi
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["data"]; print(d["type"], d["deletion_allowed"], d["exportable"], d["allow_plaintext_backup"])' "$work/api.json"
}
# The live ansible policy against a file: the same text, ignoring trailing newlines on both sides
# when the second argument is "ignoring", or byte for byte otherwise.
policy_matches() {
  api_expect 200 'ansible policy read' GET sys/policies/acl/ansible admin_token
  python3 - "$work/api.json" "$1" "${2:-exact}" <<'PY'
import json, pathlib, sys
live, wanted = json.load(open(sys.argv[1]))['data']['policy'], pathlib.Path(sys.argv[2]).read_text()
if sys.argv[3] == 'ignoring':
    live, wanted = live.rstrip('\n'), wanted.rstrip('\n')
sys.exit(0 if live == wanted else 1)
PY
}
policy_file=roles/openbao/files/ansible-policy.hcl
# Write a policy file's text as the ansible policy, as keepbreath0.
write_ansible_policy() {
  api_expect 204 "write $1 as the ansible policy" POST sys/policies/acl/ansible admin_token \
    "$(python3 -c 'import json,pathlib,sys; print(json.dumps({"policy": pathlib.Path(sys.argv[1]).read_text()}))' "$1")"
}
not_removed_folder() {
  local log=$1 folder=$2
  if grep -Fq "(item=$folder)" "$log"; then fail "the folder task must not report $folder"; fi
}
# Every consumer folder left under any account's .config/openbao/approle/, hidden ones included.
consumer_folders() {
  python3 - <<'PY'
import pathlib
for home in sorted(pathlib.Path('/home').iterdir()):
    folder = home / '.config' / 'openbao' / 'approle'
    if folder.is_dir():
        for entry in sorted(folder.iterdir()):
            if entry.is_dir():
                print(entry)
PY
}
saved_ids_index=0
save_ids() {
  local name=$1
  saved_ids_index=$((saved_ids_index + 1))
  cp "/home/bctest/.config/openbao/approle/$name/role-id" "$work/saved-$name-role-id"
  cp "/home/bctest/.config/openbao/approle/$name/secret-id" "$work/saved-$name-secret-id"
  cp "$work/saved-$name-role-id" "$work/history-$saved_ids_index-$name-role-id"
  cp "$work/saved-$name-secret-id" "$work/history-$saved_ids_index-$name-secret-id"
}
consumer_body() {
  local name=$1
  python3 - "$name" <<'PY'
import json, pathlib, sys
folder = pathlib.Path('/home/bctest/.config/openbao/approle') / sys.argv[1]
print(json.dumps({'role_id': (folder / 'role-id').read_text(),
                  'secret_id': (folder / 'secret-id').read_text()}))
PY
}
consumer_login() {
  local name=$1 address=$2 expected=$3 body
  body=$(consumer_body "$name")
  api_address=$address api_expect "$expected" "$name sign-in from $address" POST auth/approle/login '' "$body"
}
saved_body() {
  python3 - "$work" "$1" <<'PY'
import json, pathlib, sys
work, name = pathlib.Path(sys.argv[1]), sys.argv[2]
print(json.dumps({'role_id': (work / ('saved-' + name + '-role-id')).read_text(),
                  'secret_id': (work / ('saved-' + name + '-secret-id')).read_text()}))
PY
}
saved_login() {
  local name=$1 expected=$2
  api_expect "$expected" "$name saved secret ID sign-in" POST auth/approle/login '' "$(saved_body "$name")"
}
revoke_consumer() {
  local token
  token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$work/api.json")
  api_expect 204 'consumer token revoke' POST auth/token/revoke-self token
}
one_accessor() {
  local name=$1 expected
  api_expect 200 "$name file accessor" POST "auth/approle/role/$name/secret-id/lookup" admin_token \
    "$(python3 - "$name" <<'PY'
import json, pathlib, sys
print(json.dumps({'secret_id': (pathlib.Path('/home/bctest/.config/openbao/approle') / sys.argv[1] / 'secret-id').read_text()}))
PY
)"
  expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["secret_id_accessor"])' "$work/api.json")
  api_expect 200 "$name accessor list" LIST "auth/approle/role/$name/secret-id" admin_token
  python3 - "$work/api.json" "$expected" <<'PY' || fail "$name must have exactly its file accessor"
import json, sys
assert json.load(open(sys.argv[1]))['data']['keys'] == [sys.argv[2]]
PY
}

# Argument validation.
if ansible-playbook -i localhost, tests/openbao_config/missing-password.yml >"$work/missing-password.log" 2>&1; then
  fail 'missing openbao_ansible_password must fail'
fi
grep -Fq 'missing required arguments: openbao_ansible_password' "$work/missing-password.log" || fail 'missing password must fail argument validation'

# Before any OpenBao exists: check mode reports both mounts, and a real run refuses.
play role --check --diff
reports_both_mounts "$last_play_log"
# With a transit key listed, check mode also reports transit/ beside the two mounts.
play role --check --diff -e '{"openbao_transit_keys":["tofu-durable"]}'
reports "$last_play_log" 'openbao_config would enable transit/'
reports "$last_play_log" 'openbao_config would enable secret/ as a version 2 key/value store'
reports "$last_play_log" 'openbao_config would enable approle/'
recap "$last_play_log" 3
play role --check --diff -e "@$work/consumers.json"
for name in testsvc othersvc; do
  for message in "openbao_config would write the policy $name" "openbao_config would write the AppRole $name" "openbao_config would issue a secret ID for $name and write its files"; do
    grep -Fq "\"msg\": \"$message\"" "$last_play_log" || fail "missing check-mode message: $message"
  done
done
play role --check --diff -e "@$restore_list"
check_restore_report "$last_play_log"
play_fails no-openbao role 'OpenBao must answer sys/health with 200 before openbao_config runs'

# Start OpenBao through the openbao role.
play openbao
healthy || fail 'the openbao role must start OpenBao'
login keepbreath0 TEST_ADMIN_PASSWORD admin_token

# Check mode with OpenBao running reports both mounts and enables neither.
play role --check --diff
reports_both_mounts "$last_play_log"
[[ $(secret_mount) == absent ]] || fail 'check mode must not enable secret/'
[[ $(approle_mount) == absent ]] || fail 'check mode must not enable approle/'
no_ansible_tokens 'check mode'

# The first real run enables both mounts.
play role
recap "$last_play_log" 2
changed_task "$last_play_log" 'OpenBao config | Enable the key/value store'
changed_task "$last_play_log" 'OpenBao config | Enable AppRole'
[[ $(secret_mount) == 'kv 2' ]] || fail 'secret/ must be a version 2 key/value store after the first run'
[[ $(approle_mount) == approle ]] || fail 'approle/ must be an AppRole auth method after the first run'
no_ansible_tokens 'the first run'

# A second run and a check run change nothing.
play role
recap "$last_play_log" 0
play role --check --diff
recap "$last_play_log" 0
play verify
no_ansible_tokens 'the second run, check run and verify'

# The first-start grant: ansible writes the restore-check test secret but can't read it or
# write anywhere else under secret/.
login ansible TEST_ANSIBLE_PASSWORD ansible_token
api_expect 200 'ansible write to secret/data/restore-check/test' POST secret/data/restore-check/test ansible_token '{"data":{"value":"restore-check-test"}}'
api_expect 403 'ansible read of secret/data/restore-check/test' GET secret/data/restore-check/test ansible_token
api_expect 403 'ansible write to secret/data/other/test' POST secret/data/other/test ansible_token '{"data":{"value":"other"}}'
api_expect 204 'ansible token revoke' POST auth/token/revoke-self ansible_token

# An existing secret/ of the wrong version is refused and left alone.
api_expect 204 'disable secret/' DELETE sys/mounts/secret admin_token
api_expect 204 'enable secret/ as version 1' POST sys/mounts/secret admin_token '{"type":"kv","options":{"version":"1"}}'
play_fails wrong-version role 'secret/ must be a version 2 key/value store'
[[ $(secret_mount) == 'kv 1' ]] || fail 'the role must not rewrite an existing secret/'
no_ansible_tokens 'the failed run'
api_expect 204 'disable version 1 secret/' DELETE sys/mounts/secret admin_token
play role
changed_task "$last_play_log" 'OpenBao config | Enable the key/value store'
[[ $(secret_mount) == 'kv 2' ]] || fail 'the role must enable secret/ again as version 2'
no_ansible_tokens 'the repair run'
api_expect 200 'testsvc probe write' POST secret/data/testsvc/probe admin_token '{"data":{"value":"testsvc-probe"}}'
api_expect 200 'othersvc probe write' POST secret/data/othersvc/probe admin_token '{"data":{"value":"othersvc-probe"}}'

# Consumers are added only after the 3.2a repair case has finished.
play role --check --diff -e "@$work/consumers.json"
for name in testsvc othersvc; do
  for message in "openbao_config would write the policy $name" "openbao_config would write the AppRole $name" "openbao_config would issue a secret ID for $name and write its files"; do
    grep -Fq "\"msg\": \"$message\"" "$last_play_log" || fail "missing check-mode message: $message"
  done
done
api_expect 404 'check mode must not write testsvc policy' GET sys/policies/acl/testsvc admin_token
api_expect 404 'check mode must not write testsvc AppRole' GET auth/approle/role/testsvc admin_token
[[ ! -e /home/bctest/.config/openbao/approle ]] || fail 'check mode must not write the approle folder'

play role -e "@$work/consumers.json"
for name in testsvc othersvc; do
  api_expect 200 "$name policy read" GET "sys/policies/acl/$name" admin_token
  python3 - "$work/api.json" "$name" <<'PY' || fail 'consumer policy must match exactly'
import json, sys
actual = json.load(open(sys.argv[1]))['data']['policy']
expected = 'path "secret/data/' + sys.argv[2] + '/*" {\n  capabilities = ["read"]\n}\n'
assert actual == expected, (actual, expected)
PY
  api_expect 200 "$name AppRole read" GET "auth/approle/role/$name" admin_token
  python3 - "$work/api.json" "$name" <<'PY' || fail 'consumer AppRole settings must match'
import json, sys
data = json.load(open(sys.argv[1]))['data']
expected = dict(secret_id_ttl=0, secret_id_num_uses=0,
    secret_id_bound_cidrs=['192.0.2.10/32', '2001:db8::10/128'],
    token_bound_cidrs=['192.0.2.10', '2001:db8::10'], token_ttl=300,
    token_max_ttl=300, token_policies=[sys.argv[2]])
assert {key: data[key] for key in expected} == expected
PY
  api_expect 200 "$name role ID read" GET "auth/approle/role/$name/role-id" admin_token
  python3 - "$work/api.json" "$name" <<'PY' || fail 'role ID file must match OpenBao'
import json, pathlib, pwd, sys
name = sys.argv[2]
folder = pathlib.Path('/home/bctest/.config/openbao/approle') / name
role_id = json.load(open(sys.argv[1]))['data']['role_id']
assert (folder / 'role-id').read_text() == role_id
assert folder.stat().st_mode & 0o777 == 0o700
assert folder.stat().st_uid == pwd.getpwnam('bctest').pw_uid
for filename in ('role-id', 'secret-id'):
    path = folder / filename
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.stat().st_uid == pwd.getpwnam('bctest').pw_uid
PY
done

save_ids testsvc
save_ids othersvc
consumer_login testsvc 192.0.2.10 200
python3 - "$work/api.json" <<'PY' || fail 'testsvc token must have default and testsvc policies'
import json, sys
assert json.load(open(sys.argv[1]))['auth']['policies'] == ['default', 'testsvc']
PY
consumer_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$work/api.json")
api_expect 200 'testsvc reads its own probe' GET secret/data/testsvc/probe consumer_token
python3 - "$work/api.json" <<'PY' || fail 'testsvc probe value must match'
import json, sys
assert json.load(open(sys.argv[1]))['data']['data']['value'] == 'testsvc-probe'
PY
api_expect 403 'testsvc cannot read othersvc' GET secret/data/othersvc/probe consumer_token
api_address=198.51.100.7 api_expect 403 'bound token cannot move' GET secret/data/testsvc/probe consumer_token
grep -Fq 'permission denied' "$work/api.json" || fail 'moved token refusal must say permission denied'
api_expect 204 'testsvc token revoke' POST auth/token/revoke-self consumer_token
consumer_login testsvc 2001:db8::10 200
python3 - "$work/api.json" <<'PY' || fail 'IPv6 testsvc token must have default and testsvc policies'
import json, sys
assert json.load(open(sys.argv[1]))['auth']['policies'] == ['default', 'testsvc']
PY
revoke_consumer
consumer_login testsvc 198.51.100.7 400
grep -Fq 'source address \"198.51.100.7\" unauthorized by CIDR restrictions on the role' "$work/api.json" || fail 'unbound sign-in must cite CIDR restrictions'
one_accessor testsvc
one_accessor othersvc
no_ansible_tokens 'consumer sign-ins'

play role -e "@$work/consumers.json"
recap "$last_play_log" 0
play role --check --diff -e "@$work/consumers.json"
recap "$last_play_log" 0
for name in testsvc othersvc; do
  cmp -s "$work/saved-$name-role-id" "/home/bctest/.config/openbao/approle/$name/role-id" || fail "$name role ID changed on no-op runs"
  cmp -s "$work/saved-$name-secret-id" "/home/bctest/.config/openbao/approle/$name/secret-id" || fail "$name secret ID changed on no-op runs"
done
no_ansible_tokens 'consumer no-op runs'

# A missing file is only reported in check mode. The real run rotates it and destroys its old ID.
rm /home/bctest/.config/openbao/approle/testsvc/secret-id
play role --check --diff -e "@$work/consumers.json"
grep -Fq 'openbao_config would issue a secret ID for testsvc and write its files' "$last_play_log" || fail 'missing secret ID must be reported'
[[ $(grep -Fc 'openbao_config would destroy a secret ID of testsvc that isn'"'"'t in its file' "$last_play_log") == 1 ]] || fail 'missing file must report exactly one old accessor'
[[ ! -e /home/bctest/.config/openbao/approle/testsvc/secret-id ]] || fail 'check mode must leave missing file missing'
saved_login testsvc 200
revoke_consumer
play role -e "@$work/consumers.json"
consumer_login testsvc 192.0.2.10 200
revoke_consumer
saved_login testsvc 400
grep -Fq 'invalid role or secret ID' "$work/api.json" || fail 'lost-file secret ID must be revoked'
one_accessor testsvc
save_ids testsvc
no_ansible_tokens 'lost-file recovery'

# A revoked ID in the file is replaced; an extra live ID is destroyed without changing the file.
api_expect 204 'destroy file secret ID' POST auth/approle/role/testsvc/secret-id/destroy admin_token \
  "$(python3 - <<'PY'
import json, pathlib
print(json.dumps({'secret_id': pathlib.Path('/home/bctest/.config/openbao/approle/testsvc/secret-id').read_text()}))
PY
)"
play role -e "@$work/consumers.json"
cmp -s "$work/saved-testsvc-secret-id" /home/bctest/.config/openbao/approle/testsvc/secret-id && fail 'revoked file secret ID must be replaced'
consumer_login testsvc 192.0.2.10 200
revoke_consumer
one_accessor testsvc
save_ids testsvc
api_expect 200 'issue extra secret ID' POST auth/approle/role/testsvc/secret-id admin_token
python3 - "$work/api.json" "$work/extra-secret-id" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(json.load(open(sys.argv[1]))['data']['secret_id'])
PY
play role --check --diff -e "@$work/consumers.json"
[[ $(grep -Fc 'openbao_config would destroy a secret ID of testsvc that isn'"'"'t in its file' "$last_play_log") == 1 ]] || fail 'extra ID must have one check-mode report'
api_expect 200 'extra ID still works in check mode' POST auth/approle/login '' \
  "$(python3 - "$work" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
print(json.dumps({'role_id': (work / 'saved-testsvc-role-id').read_text(), 'secret_id': (work / 'extra-secret-id').read_text()}))
PY
)"
revoke_consumer
play role -e "@$work/consumers.json"
cmp -s "$work/saved-testsvc-secret-id" /home/bctest/.config/openbao/approle/testsvc/secret-id || fail 'extra ID cleanup must keep the file'
api_expect 400 'extra ID must be destroyed' POST auth/approle/login '' \
  "$(python3 - "$work" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
print(json.dumps({'role_id': (work / 'saved-testsvc-role-id').read_text(), 'secret_id': (work / 'extra-secret-id').read_text()}))
PY
)"
grep -Fq 'invalid role or secret ID' "$work/api.json" || fail 'extra ID must be invalid'
one_accessor testsvc
no_ansible_tokens 'revoked and extra ID recovery'

rm /home/bctest/.config/openbao/approle/testsvc/role-id
play role -e "@$work/consumers.json"
cmp -s "$work/saved-testsvc-role-id" /home/bctest/.config/openbao/approle/testsvc/role-id || fail 'role ID repair must restore the same ID'
cmp -s "$work/saved-testsvc-secret-id" /home/bctest/.config/openbao/approle/testsvc/secret-id || fail 'role ID repair must keep secret ID'

api_expect 204 'drift policy' POST sys/policies/acl/testsvc admin_token '{"policy":"path \"secret/data/*\" { capabilities = [\"read\"] }"}'
api_expect 204 'drift token TTL' POST auth/approle/role/testsvc admin_token '{"token_ttl":120}'
play role -e "@$work/consumers.json"
api_expect 200 'repaired policy' GET sys/policies/acl/testsvc admin_token
python3 - "$work/api.json" <<'PY' || fail 'policy must be repaired exactly'
import json, sys
assert json.load(open(sys.argv[1]))['data']['policy'] == 'path "secret/data/testsvc/*" {\n  capabilities = ["read"]\n}\n'
PY
api_expect 200 'repaired token TTL' GET auth/approle/role/testsvc admin_token
python3 - "$work/api.json" <<'PY' || fail 'AppRole TTL must be 300 after repair'
import json, sys
assert json.load(open(sys.argv[1]))['data']['token_ttl'] == 300
PY
cmp -s "$work/saved-testsvc-secret-id" /home/bctest/.config/openbao/approle/testsvc/secret-id || fail 'settings repair must keep secret ID'
consumer_login testsvc 192.0.2.10 200
revoke_consumer

play_fails_contains moved-address role "testsvc's secret ID file was refused for a reason a new secret ID can't fix: 400 source address" \
  -e "@$work/consumers.json" -e '{"openbao_approle_bound_cidrs":["198.51.100.0/24"]}'
cmp -s "$work/saved-testsvc-secret-id" /home/bctest/.config/openbao/approle/testsvc/secret-id || fail 'CIDR refusal must keep secret ID'
play role -e "@$work/consumers.json"
consumer_login testsvc 192.0.2.10 200
revoke_consumer
no_ansible_tokens 'CIDR refusal and repair'

# Standalone verify detects each kind of drift before a role run repairs it.
api_expect 204 'drift policy for verify' POST sys/policies/acl/testsvc admin_token '{"policy":"path \"secret/data/*\" { capabilities = [\"read\"] }"}'
play_fails verify-policy verify 'the policy testsvc must match openbao_approles' -e "@$work/consumers.json"
no_ansible_tokens 'policy verify failure'
play role -e "@$work/consumers.json"
api_expect 204 'drift role for verify' POST auth/approle/role/testsvc admin_token '{"token_ttl":120}'
play_fails verify-role verify 'the AppRole testsvc must have the settings decision 51 sets' -e "@$work/consumers.json"
no_ansible_tokens 'AppRole verify failure'
play role -e "@$work/consumers.json"
chmod 644 /home/bctest/.config/openbao/approle/testsvc/secret-id
play_fails verify-mode verify "testsvc's files must be owned by bctest and readable by it alone" -e "@$work/consumers.json"
no_ansible_tokens 'file-mode verify failure'
play role -e "@$work/consumers.json"
[[ $(stat -c %a /home/bctest/.config/openbao/approle/testsvc/secret-id) == 600 ]] || fail 'role must repair secret ID file mode'
api_expect 204 'destroy file secret ID for verify' POST auth/approle/role/testsvc/secret-id/destroy admin_token \
  "$(python3 - <<'PY'
import json, pathlib
print(json.dumps({'secret_id': pathlib.Path('/home/bctest/.config/openbao/approle/testsvc/secret-id').read_text()}))
PY
)"
play_fails verify-login verify "testsvc's files must sign in from openbao_self_address" -e "@$work/consumers.json"
no_ansible_tokens 'sign-in verify failure'
play role -e "@$work/consumers.json"
api_expect 200 'issue extra ID for verify' POST auth/approle/role/testsvc/secret-id admin_token
python3 - "$work/api.json" "$work/verify-extra-secret-id" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(json.load(open(sys.argv[1]))['data']['secret_id'])
PY
play_fails verify-extra verify 'testsvc must have exactly one secret ID, the one in its file' -e "@$work/consumers.json"
no_ansible_tokens 'extra-ID verify failure'
play role -e "@$work/consumers.json"
save_ids testsvc
play verify -e "@$work/consumers.json"
one_accessor testsvc
no_ansible_tokens 'verify repair'

# A shorter IPv6 prefix stays a network in OpenBao's token-bound address list.
wide_cidrs='{"openbao_approle_bound_cidrs":["192.0.2.10/32","2001:db8::/32","198.51.100.0/24","2001:db8::10/128"]}'
play role -e "@$work/consumers.json" -e "$wide_cidrs"
api_expect 200 'read AppRole with IPv6 network' GET auth/approle/role/testsvc admin_token
python3 - "$work/api.json" <<'PY' || fail 'token-bound addresses must preserve the IPv6 /32 network'
import json, sys
assert json.load(open(sys.argv[1]))['data']['token_bound_cidrs'] == [
    '192.0.2.10', '2001:db8::/32', '198.51.100.0/24', '2001:db8::10']
PY
play role -e "@$work/consumers.json" -e "$wide_cidrs"
recap "$last_play_log" 0
play verify -e "@$work/consumers.json" -e "$wide_cidrs"
play role -e "@$work/consumers.json"
no_ansible_tokens 'IPv6 network comparison'

api_expect 200 'read ansible policy before reserved names' GET sys/policies/acl/ansible admin_token
cp "$work/api.json" "$work/ansible-policy.json"
for name in ansible keepbreath0 default root; do
  play_fails "reserved-$name" role 'openbao_approles must not name ansible, keepbreath0, default or root' \
    -e "{\"openbao_approles\":[{\"name\":\"$name\",\"account\":\"bctest\"}]}"
done
api_expect 200 'read ansible policy after reserved names' GET sys/policies/acl/ansible admin_token
python3 - "$work/ansible-policy.json" "$work/api.json" <<'PY' || fail 'reserved names must leave ansible policy unchanged'
import json, sys
before, after = (json.load(open(path))['data']['policy'] for path in sys.argv[1:])
assert before == after
PY
play_fails bad-name role 'openbao_approles names must match ^[a-z][a-z0-9-]*$' \
  -e '{"openbao_approles":[{"name":"Bad_Name","account":"bctest"}]}'
play_fails duplicate role 'openbao_approles names must be unique' \
  -e '{"openbao_approles":[{"name":"testsvc","account":"bctest"},{"name":"testsvc","account":"bctest"}]}'
play_fails missing-account role 'openbao_approles account bcnone must exist before openbao_config runs' \
  -e '{"openbao_approles":[{"name":"svcnone","account":"bcnone"}]}'
api_expect 404 'missing account must not create AppRole' GET auth/approle/role/svcnone admin_token
play role --check --diff -e '{"openbao_approles":[{"name":"svcnone","account":"bcnone"}]}'
grep -Fq 'openbao_config would issue a secret ID for svcnone and write its files' "$last_play_log" || fail 'check mode must report missing-account files'
no_ansible_tokens 'input refusal and missing-account check'

# 3.2c begins with an absent test secret, after 3.2a exercised its grant.
api_expect 204 'remove the 3.2a test secret' DELETE secret/metadata/restore-check/test admin_token
play role --check --diff -e "@$restore_list"
check_restore_report "$last_play_log"
api_expect 404 'check mode leaves snapshot policy absent' GET sys/policies/acl/openbao-snapshot admin_token
api_expect 404 'check mode leaves test secret absent' GET secret/metadata/restore-check/test admin_token
play role -e "@$restore_list"
api_expect 200 'snapshot policy' GET sys/policies/acl/openbao-snapshot admin_token
python3 - "$work/api.json" <<'PY' || fail 'snapshot policy must match the wanted text'
import json,sys
assert json.load(open(sys.argv[1]))['data']['policy'] == 'path "secret/data/openbao-snapshot/*" {\n  capabilities = ["read"]\n}\n\npath "sys/storage/raft/snapshot" {\n  capabilities = ["read"]\n}\n'
PY
api_expect 200 'restore-check policy' GET sys/policies/acl/restore-check admin_token
python3 - "$work/api.json" <<'PY' || fail 'restore-check must have only its own policy block'
import json,sys
assert json.load(open(sys.argv[1]))['data']['policy'] == 'path "secret/data/restore-check/*" {\n  capabilities = ["read"]\n}\n'
PY
for name in restore-check openbao-snapshot; do
  api_expect 200 "$name AppRole settings" GET "auth/approle/role/$name" admin_token
  python3 - "$work/api.json" "$name" <<'PY' || fail "$name AppRole must have decision 51's settings"
import json,sys
data=json.load(open(sys.argv[1]))['data']
assert data['secret_id_ttl']==0 and data['secret_id_num_uses']==0
assert data['secret_id_bound_cidrs']==['192.0.2.10/32','2001:db8::10/128']
assert data['token_bound_cidrs']==['192.0.2.10','2001:db8::10']
assert data['token_ttl']==300 and data['token_max_ttl']==300
assert data['token_policies']==[sys.argv[2]]
PY
done
save_ids openbao-snapshot
python3 - <<'PY' || fail 'snapshot files must be private to bctest'
import pathlib,pwd,stat
folder=pathlib.Path('/home/bctest/.config/openbao/approle/openbao-snapshot')
uid=pwd.getpwnam('bctest').pw_uid
assert folder.stat().st_uid==uid and stat.S_IMODE(folder.stat().st_mode)==0o700
for name in ('role-id','secret-id'):
    path=folder/name
    assert path.stat().st_uid==uid and stat.S_IMODE(path.stat().st_mode)==0o600
PY
if compgen -G '/home/*/.config/openbao/approle/restore-check' >/dev/null; then
  fail 'restore-check must have no files in any account'
fi
api_expect 404 'restore-check has no secret IDs' LIST auth/approle/role/restore-check/secret-id admin_token
api_expect 200 'test secret value' GET secret/data/restore-check/test admin_token
python3 - "$work/api.json" 1 <<'PY' || fail 'test secret must have the expected value and version'
import json,sys
data=json.load(open(sys.argv[1]))['data']
assert data['data']['value']=='restore-check-test' and data['metadata']['version']==int(sys.argv[2])
PY
python3 - "$restore_list" "$work/two-paths.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
data['openbao_approles'][1]['extra_paths'].append(
    {'path':'sys/health','capabilities':['read','list']})
with open(sys.argv[2],'w') as stream:
    json.dump(data,stream)
PY
play role -e "@$work/two-paths.json"
api_expect 200 'two-path policy' GET sys/policies/acl/openbao-snapshot admin_token
python3 - "$work/api.json" <<'PY' || fail 'extra policy paths must retain list order and JSON capabilities'
import json,sys
assert json.load(open(sys.argv[1]))['data']['policy'] == 'path "secret/data/openbao-snapshot/*" {\n  capabilities = ["read"]\n}\n\npath "sys/storage/raft/snapshot" {\n  capabilities = ["read"]\n}\n\npath "sys/health" {\n  capabilities = ["read", "list"]\n}\n'
PY
play role -e "@$restore_list"
consumer_login openbao-snapshot 192.0.2.10 200
python3 - "$work/api.json" <<'PY' || fail 'snapshot token must have default and openbao-snapshot policies'
import json,sys
assert json.load(open(sys.argv[1]))['auth']['policies']==['default','openbao-snapshot']
PY
snapshot_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$work/api.json")
api_expect 200 'snapshot read' GET sys/storage/raft/snapshot snapshot_token
[[ $(wc -c <"$work/api.json") -gt 0 ]] || fail 'snapshot must have a body'
api_expect 403 'snapshot restore refused' POST sys/storage/raft/snapshot snapshot_token
api_expect 403 'snapshot test secret refused' GET secret/data/restore-check/test snapshot_token
api_expect 204 'snapshot token revoke' POST auth/token/revoke-self snapshot_token
api_expect 200 'restore-check role ID' GET auth/approle/role/restore-check/role-id admin_token
restore_role_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["role_id"])' "$work/api.json")
printf '%s' "$restore_role_id" >"$work/restore-check-role-id"
api_expect 200 'issue restore-check secret ID' POST auth/approle/role/restore-check/secret-id admin_token
restore_secret_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["secret_id"])' "$work/api.json")
restore_accessor=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["secret_id_accessor"])' "$work/api.json")
printf '%s' "$restore_secret_id" >"$work/restore-check-secret-id"
restore_body=$(RESTORE_ROLE_ID=$restore_role_id RESTORE_SECRET_ID=$restore_secret_id python3 -c 'import json,os; print(json.dumps({"role_id":os.environ["RESTORE_ROLE_ID"],"secret_id":os.environ["RESTORE_SECRET_ID"]}))')
api_expect 200 'restore-check sign-in' POST auth/approle/login '' "$restore_body"
restore_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$work/api.json")
api_expect 200 'restore-check reads its test secret' GET secret/data/restore-check/test restore_token
python3 - "$work/api.json" <<'PY' || fail 'restore-check must read the value Ansible wrote'
import json,sys
assert json.load(open(sys.argv[1]))['data']['data']['value']=='restore-check-test'
PY
api_expect 204 'restore-check token revoke' POST auth/token/revoke-self restore_token
play role -e "@$restore_list"
recap "$last_play_log" 0
play role --check --diff -e "@$restore_list"
recap "$last_play_log" 0
api_expect 200 'test secret after no-op runs' GET secret/data/restore-check/test admin_token
python3 - "$work/api.json" <<'PY' || fail 'no-op runs must leave the test secret at version 1'
import json,sys
assert json.load(open(sys.argv[1]))['data']['metadata']['version']==1
PY
play verify -e "@$restore_list"
api_expect 200 'restore-check still signs in' POST auth/approle/login '' "$restore_body"
revoke_consumer
api_expect 200 'restore-check accessor survives' LIST auth/approle/role/restore-check/secret-id admin_token
python3 - "$work/api.json" "$restore_accessor" <<'PY' || fail 'restore-check accessor must survive'
import json,sys
assert json.load(open(sys.argv[1]))['data']['keys']==[sys.argv[2]]
PY
api_expect 204 'soft-delete test secret' DELETE secret/data/restore-check/test admin_token
play role --check --diff -e "@$restore_list"
grep -Fq "openbao_config would write restore-check's test secret" "$last_play_log" || fail 'check mode must report deleted test secret'
api_expect 404 'check mode leaves test secret deleted' GET secret/data/restore-check/test admin_token
play_fails verify-deleted verify "restore-check's test secret must exist" -e "@$restore_list"
play role -e "@$restore_list"
api_expect 200 'repaired test secret' GET secret/data/restore-check/test admin_token
python3 - "$work/api.json" 2 <<'PY' || fail 'soft-deleted test secret must be version 2'
import json,sys
data=json.load(open(sys.argv[1]))['data']
assert data['data']['value']=='restore-check-test' and data['metadata']['version']==int(sys.argv[2])
PY
play verify -e "@$restore_list"
api_expect 204 'destroy test secret version 2' PUT secret/destroy/restore-check/test admin_token '{"versions":[2]}'
play role -e "@$restore_list"
api_expect 200 'version 3 test secret' GET secret/data/restore-check/test admin_token
python3 - "$work/api.json" <<'PY' || fail 'destroyed test secret must be version 3'
import json,sys
data=json.load(open(sys.argv[1]))['data']
assert data['data']['value']=='restore-check-test' and data['metadata']['version']==3
PY
api_expect 204 'delete test secret metadata' DELETE secret/metadata/restore-check/test admin_token
printf '%s\n' '{"openbao_approles":[{"name":"openbao-snapshot","account":"bctest","extra_paths":[{"path":"sys/storage/raft/snapshot","capabilities":["read"]}]}]}' >"$work/snapshot-only.json"
play role -e "@$work/snapshot-only.json"
api_expect 404 'no reader means no test secret' GET secret/metadata/restore-check/test admin_token
play role -e "@$restore_list"
api_expect 200 'test secret returns at version 1' GET secret/data/restore-check/test admin_token
python3 - "$work/api.json" <<'PY' || fail 'test secret after metadata deletion must be version 1'
import json,sys
data=json.load(open(sys.argv[1]))['data']
assert data['data']['value']=='restore-check-test' and data['metadata']['version']==1
PY
play_fails missing-files-account role 'openbao_approles entry svcnoacct must name an account, because it has files' -e '{"openbao_approles":[{"name":"svcnoacct"}]}'
api_expect 404 'missing files account creates no AppRole' GET auth/approle/role/svcnoacct admin_token
login ansible TEST_ANSIBLE_PASSWORD ansible_token
api_expect 200 'ansible reads test metadata' GET secret/metadata/restore-check/test ansible_token
api_expect 403 'ansible cannot read test value' GET secret/data/restore-check/test ansible_token
api_expect 403 'ansible cannot read other metadata' GET secret/metadata/other/test ansible_token
api_expect 204 'ansible token revoke' POST auth/token/revoke-self ansible_token
no_ansible_tokens '3.2c cases'

# 3.2d: openbao_approles is the whole truth. Each case first applies all four entries, so the
# AppRoles, policies and folders it expects gone exist before an entry comes off the list.
reserved_check=1
approle_dir=/home/bctest/.config/openbao/approle
full_list=$work/full-consumers.json
testsvc_list=$work/testsvc-only.json
printf '%s\n' '{"openbao_approles":[{"name":"testsvc","account":"bctest"},{"name":"othersvc","account":"bctest"},{"name":"restore-check","files":false},{"name":"openbao-snapshot","account":"bctest","extra_paths":[{"path":"sys/storage/raft/snapshot","capabilities":["read"]}]}]}' >"$full_list"
printf '%s\n' '{"openbao_approles":[{"name":"testsvc","account":"bctest"}]}' >"$testsvc_list"
play role -e "@$full_list"
for name in testsvc othersvc restore-check openbao-snapshot; do
  api_expect 200 "$name AppRole before removal" GET "auth/approle/role/$name" admin_token
  api_expect 200 "$name policy before removal" GET "sys/policies/acl/$name" admin_token
done
for name in testsvc othersvc openbao-snapshot; do
  [[ -d $approle_dir/$name ]] || fail "the $name folder must exist before removal"
done
save_ids testsvc
save_ids othersvc
consumer_state testsvc >"$work/testsvc-state-before.json"

# The dry run reports every deletion and deletes nothing.
play role --check --diff -e "@$testsvc_list"
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$last_play_log" || { tail -40 "$last_play_log"; fail 'the removal dry run must finish with failed=0'; }
for name in othersvc restore-check openbao-snapshot; do
  for kind in AppRole policy; do
    grep -Fq "\"msg\": \"openbao_config would delete the $kind $name\"" "$last_play_log" || fail "check mode must report: openbao_config would delete the $kind $name"
  done
done
removed_folder "$last_play_log" "$approle_dir/othersvc"
removed_folder "$last_play_log" "$approle_dir/openbao-snapshot"
not_removed_folder "$last_play_log" "$approle_dir/testsvc"
if grep -Fq 'openbao_config would delete the AppRole testsvc' "$last_play_log"; then fail 'check mode must not report deleting testsvc'; fi
for name in testsvc othersvc restore-check openbao-snapshot; do
  api_expect 200 "$name AppRole after the dry run" GET "auth/approle/role/$name" admin_token
  api_expect 200 "$name policy after the dry run" GET "sys/policies/acl/$name" admin_token
done
for name in othersvc openbao-snapshot; do
  [[ -d $approle_dir/$name ]] || fail "check mode must leave the $name folder"
done

# The real run deletes them; testsvc is untouched and othersvc's secret ID stops working.
play role -e "@$testsvc_list"
for name in othersvc restore-check openbao-snapshot; do
  api_expect 404 "$name AppRole after removal" GET "auth/approle/role/$name" admin_token
  api_expect 404 "$name policy after removal" GET "sys/policies/acl/$name" admin_token
done
for name in othersvc openbao-snapshot; do
  [[ ! -e $approle_dir/$name ]] || fail "the $name folder must be removed"
done
consumer_state testsvc >"$work/testsvc-state-after.json"
cmp -s "$work/testsvc-state-before.json" "$work/testsvc-state-after.json" || fail "testsvc's AppRole, policy and folder must be unchanged"
saved_login othersvc 400
grep -Fq 'invalid role or secret ID' "$work/api.json" || fail "othersvc's secret ID must be refused with invalid role or secret ID"
play role -e "@$testsvc_list"
recap "$last_play_log" 0
play role --check --diff -e "@$testsvc_list"
recap "$last_play_log" 0

# A policy written by hand is reported in check mode and deleted by the real run.
api_expect 204 'handmade policy write' POST sys/policies/acl/handmade admin_token '{"policy":"path \"secret/data/handmade/*\" { capabilities = [\"read\"] }"}'
play role --check --diff -e "@$testsvc_list"
grep -Fq '"msg": "openbao_config would delete the policy handmade"' "$last_play_log" || fail 'check mode must report: openbao_config would delete the policy handmade'
api_expect 200 'check mode keeps the handmade policy' GET sys/policies/acl/handmade admin_token
play role -e "@$testsvc_list"
api_expect 404 'handmade policy after the real run' GET sys/policies/acl/handmade admin_token

# A folder for testsvc under another account is removed; bctest's is untouched.
useradd -m bcother
undo_add 'remove driver-created bcother' remove_bcother
install -d -o bcother -g bcother -m 0700 /home/bcother/.config /home/bcother/.config/openbao \
  /home/bcother/.config/openbao/approle /home/bcother/.config/openbao/approle/testsvc
printf 'stray' >/home/bcother/.config/openbao/approle/testsvc/secret-id
play role -e "@$testsvc_list"
[[ ! -e /home/bcother/.config/openbao/approle/testsvc ]] || fail "bcother's testsvc folder must be removed"
consumer_state testsvc >"$work/testsvc-state-after-bcother.json"
cmp -s "$work/testsvc-state-before.json" "$work/testsvc-state-after-bcother.json" || fail "bctest's testsvc folder must be untouched"

# A folder name holding a newline can't make the role remove anything outside an approle folder.
# Read line by line, this name would also print the path /home/bctest, which holds a planted file.
odd_folder=/home/bcother/.config/openbao/approle/$'x\nbctest'
install -d -o bcother -g bcother -m 0700 "$odd_folder"
printf 'planted' >/home/bctest/planted
play role -e "@$testsvc_list"
[[ -f /home/bctest/planted ]] || fail 'a folder name holding a newline must not lead the role to remove /home/bctest'
consumer_state testsvc >"$work/testsvc-state-after-newline.json"
cmp -s "$work/testsvc-state-before.json" "$work/testsvc-state-after-newline.json" || fail "a folder name holding a newline must leave bctest's testsvc folder untouched"
[[ -d $odd_folder ]] || fail 'a folder whose path is not a consumer folder path must be skipped, not removed'
skipped_warning "$last_play_log" "$odd_folder" 'because its path is not /home/<account>/.config/openbao/approle/<name>'
rm -r -- "$odd_folder" /home/bctest/planted

# A link swapped in after find has listed the folders can't redirect the removal. The race_swap
# callback in callback_plugins/ runs once the role's find task has finished, and turns one part of
# the path from .config down to bcother's testsvc folder into a link to a tree outside /home that
# holds a planted file where the removal would land.
race_folder=/home/bcother/.config/openbao/approle/testsvc
race_index=0
for level in .config .config/openbao .config/openbao/approle .config/openbao/approle/testsvc; do
  race_index=$((race_index + 1))
  install -d -o bcother -g bcother -m 0700 /home/bcother/.config /home/bcother/.config/openbao \
    /home/bcother/.config/openbao/approle "$race_folder"
  remainder=${race_folder#"/home/bcother/$level"}
  target=$work/outside-$race_index
  mkdir -p "$target$remainder"
  printf 'planted' >"$target$remainder/planted"
  RACE_SWAP=/home/bcother/$level RACE_TARGET=$target ANSIBLE_CALLBACK_PLUGINS=$PWD/tests/openbao_config/callback_plugins \
    ANSIBLE_CALLBACKS_ENABLED=race_swap play role -e "@$testsvc_list"
  [[ -L /home/bcother/$level ]] || fail "the race_swap callback must have swapped /home/bcother/$level for a link"
  [[ -f $target$remainder/planted ]] || fail "a link at /home/bcother/$level must not lead the role to remove $target$remainder"
  skipped_warning "$last_play_log" "$race_folder" 'because it or a folder above it, up to .config, is a symbolic link or not a folder'
  consumer_state testsvc >"$work/testsvc-state-after-race-$race_index.json"
  cmp -s "$work/testsvc-state-before.json" "$work/testsvc-state-after-race-$race_index.json" || fail "a link at /home/bcother/$level must leave bctest's testsvc folder untouched"
  rm -- "/home/bcother/$level"
  mv -- "/home/bcother/$level.moved" "/home/bcother/$level"
done
# Without the swap, the same folder is removed.
play role -e "@$testsvc_list"
[[ ! -e $race_folder ]] || fail "bcother's testsvc folder must be removed once no link is in its path"

# 3.2e: everything the role does inside a consumer's home runs as that account (decision 61).
# Each link target is a root-owned folder of mode 0755 outside /home, so the account can read it
# but not change it, as it can read /etc on a real machine.
link_targets=()
remove_link_targets() {
  local target
  for target in "${link_targets[@]}"; do rm -rf -- "$target"; done
}
undo_add 'remove the 3.2e link targets' remove_link_targets

# A link planted at a consumer's folder before the run fails the run, and the folder it points
# at keeps its root owner and mode.
planted_target=$(mktemp -d)
link_targets+=("$planted_target")
chmod 0755 "$planted_target"
mv -- "$approle_dir/testsvc" "$approle_dir/testsvc.moved"
ln -s -- "$planted_target" "$approle_dir/testsvc"
play_fails planted-link role 'chown failed' -e "@$testsvc_list"
[[ $(stat -c '%U %a' "$planted_target") == 'root 755' ]] || fail "a link planted at $approle_dir/testsvc must leave $planted_target root's with mode 755"
[[ ! -e $planted_target/role-id && ! -e $planted_target/secret-id ]] || fail "a link planted at $approle_dir/testsvc must not lead the role to write into $planted_target"
rm -- "$approle_dir/testsvc"
mv -- "$approle_dir/testsvc.moved" "$approle_dir/testsvc"
play role -e "@$testsvc_list"
consumer_state testsvc >"$work/testsvc-state-after-planted-link.json"
cmp -s "$work/testsvc-state-before.json" "$work/testsvc-state-after-planted-link.json" || fail "testsvc's AppRole, policy and folder must be unchanged once the planted link is gone"
rm -rf -- "$planted_target"

# A link swapped in after the removal's stat check fails the removal, and the planted file under
# the link's target survives.
swap_target=$(mktemp -d)
link_targets+=("$swap_target")
chmod 0755 "$swap_target"
install -d -m 0755 "$swap_target/testsvc"
printf 'planted' >"$swap_target/testsvc/planted"
install -d -o bcother -g bcother -m 0700 /home/bcother/.config /home/bcother/.config/openbao \
  /home/bcother/.config/openbao/approle "$race_folder"
RACE_AFTER='OpenBao config | Look at each stale folder and its parents up to .config without following links' \
  RACE_SWAP=/home/bcother/.config/openbao/approle RACE_TARGET=$swap_target \
  ANSIBLE_CALLBACK_PLUGINS=$PWD/tests/openbao_config/callback_plugins ANSIBLE_CALLBACKS_ENABLED=race_swap \
  play_fails_contains race-after-stat role 'rmtree failed: [Errno 13] Permission denied' -e "@$testsvc_list"
[[ -L /home/bcother/.config/openbao/approle ]] || fail 'the race_swap callback must have swapped /home/bcother/.config/openbao/approle for a link after the stat task'
[[ -f $swap_target/testsvc/planted ]] || fail "a link swapped in after the stat check must not lead the removal to delete $swap_target/testsvc/planted"
consumer_state testsvc >"$work/testsvc-state-after-race-after-stat.json"
cmp -s "$work/testsvc-state-before.json" "$work/testsvc-state-after-race-after-stat.json" || fail "a link swapped in after the stat check must leave bctest's testsvc folder untouched"
rm -- /home/bcother/.config/openbao/approle
mv -- /home/bcother/.config/openbao/approle.moved /home/bcother/.config/openbao/approle
play role -e "@$testsvc_list"
[[ ! -e $race_folder ]] || fail "bcother's testsvc folder must be removed once the swapped link is gone"
rm -rf -- "$swap_target"

# A folder for an entry without files is removed.
play role -e "@$full_list"
install -d -o bctest -g bctest -m 0700 "$approle_dir/restore-check"
play role -e "@$full_list"
[[ ! -e $approle_dir/restore-check ]] || fail 'the restore-check folder must be removed, because its entry has no files'

# An empty list removes every AppRole, every consumer policy and every consumer folder.
play role -e '{"openbao_approles":[]}'
api_expect 404 'AppRole list after the empty list' LIST auth/approle/role admin_token
api_expect 200 'policy list after the empty list' LIST sys/policies/acl admin_token
python3 - "$work/api.json" <<'PY' || fail 'only ansible, default, keepbreath0 and root may remain after the empty list'
import json, sys
assert sorted(json.load(open(sys.argv[1]))['data']['keys']) == ['ansible', 'default', 'keepbreath0', 'root']
PY
[[ -z $(consumer_folders) ]] || { consumer_folders >&2; fail 'no consumer folder may remain after the empty list'; }
play role -e "@$full_list"
for name in testsvc othersvc restore-check openbao-snapshot; do
  api_expect 200 "$name AppRole recreated" GET "auth/approle/role/$name" admin_token
  api_expect 200 "$name policy recreated" GET "sys/policies/acl/$name" admin_token
done
for name in testsvc othersvc openbao-snapshot; do
  [[ -d $approle_dir/$name ]] || fail "the $name folder must be recreated"
done
play role -e "@$full_list"
recap "$last_play_log" 0
reserved_check=0

remove_bcother
if id -u bcother >/dev/null 2>&1; then fail 'the driver must remove bcother'; fi
[[ ! -e /home/bcother ]] || fail "the driver must remove bcother's home"
[[ ! -e /var/lib/systemd/linger/bcother ]] || fail 'the driver must leave bcother no lingering file'
no_ansible_tokens '3.2d cases'

# 3.5a: the role keeps the ansible policy equal to roles/openbao/files/ansible-policy.hcl, and
# manages transit/ and the transit keys openbao_transit_keys lists (OpenBao on the hub decisions
# 67 and 68). Every run applies the four consumers the last 3.2d run applied, so they never change.
both_keys='{"openbao_transit_keys":["tofu-durable","tofu-short-lived"]}'
good_key='aes256-gcm96 False False False'
# The ten policy lines first-start.hcl.j2 wrote at 9d52a87, as a server born then holds them.
old_policy=$work/old-ansible-policy.hcl
cat >"$old_policy" <<'HCL'
path "sys/mounts" { capabilities = ["read"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/auth" { capabilities = ["read"] }
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "sys/policies/acl" { capabilities = ["list"] }
path "sys/policies/acl/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/approle/role" { capabilities = ["list"] }
path "auth/approle/role/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "secret/data/restore-check/*" { capabilities = ["create", "update"] }
path "secret/metadata/restore-check/*" { capabilities = ["read"] }
HCL

# A server born from the first-start file already holds the file's policy, so nothing is
# rewritten. This run lists no key, so transit/ stays absent.
policy_matches "$policy_file" ignoring || fail 'a server born from the first-start file must hold the policy in ansible-policy.hcl'
play role -e "@$full_list"
recap "$last_play_log" 0
[[ $(transit_mount) == absent ]] || fail 'a run that lists no transit key must not enable transit/'

# A transit/ of another type is refused and left alone.
api_expect 204 'enable a key/value engine at transit/' POST sys/mounts/transit admin_token '{"type":"kv"}'
play_fails wrong-transit role 'transit/ must be a transit secrets engine' -e "@$full_list" -e "$both_keys"
[[ $(transit_mount) == kv ]] || fail 'the role must leave an existing transit/ alone'
api_expect 204 'disable the key/value engine at transit/' DELETE sys/mounts/transit admin_token
[[ $(transit_mount) == absent ]] || fail 'transit/ must be absent after the wrong-type case'

# Check mode before transit/ exists reports only the mount, even with the flag: the token's policy
# isn't widened in check mode, so no key is read.
play role --check --diff -e "@$full_list" -e "$both_keys" -e openbao_make_transit_keys=true
reports "$last_play_log" 'openbao_config would enable transit/'
recap "$last_play_log" 1
for name in tofu-durable tofu-short-lived; do
  reports_not "$last_play_log" "openbao_config would make the transit key $name"
  no_transit_warning "$last_play_log" "$name"
done
[[ $(transit_mount) == absent ]] || fail 'check mode must not enable transit/'

# A run without the flag enables transit/, makes no key and warns about each missing one.
play role -e "@$full_list" -e "$both_keys"
recap "$last_play_log" 1
changed_task "$last_play_log" 'OpenBao config | Enable transit/'
[[ $(transit_mount) == transit ]] || fail 'the role must enable transit/ as a transit secrets engine'
for name in tofu-durable tofu-short-lived; do
  transit_warning "$last_play_log" "$name"
  [[ $(key_state "$name") == 404 ]] || fail "a run without the flag must not make $name"
done

# Check mode with the flag reports each missing key and makes none. The recap counts the one
# looped report task once, however many keys it reports.
play role --check --diff -e "@$full_list" -e "$both_keys" -e openbao_make_transit_keys=true
recap "$last_play_log" 1
for name in tofu-durable tofu-short-lived; do
  reports "$last_play_log" "openbao_config would make the transit key $name"
  no_transit_warning "$last_play_log" "$name"
  [[ $(key_state "$name") == 404 ]] || fail "check mode must not make $name"
done

# The run with the flag makes both keys with OpenBao's defaults; later runs change nothing.
play role -e "@$full_list" -e "$both_keys" -e openbao_make_transit_keys=true
recap "$last_play_log" 1
changed_task "$last_play_log" 'OpenBao config | Make each missing transit key'
for name in tofu-durable tofu-short-lived; do
  no_transit_warning "$last_play_log" "$name"
  [[ $(key_state "$name") == "$good_key" ]] || fail "$name must be aes256-gcm96 with deletion, export and plaintext backup off"
done
play role -e "@$full_list" -e "$both_keys" -e openbao_make_transit_keys=true
recap "$last_play_log" 0
play role -e "@$full_list" -e "$both_keys"
recap "$last_play_log" 0
play verify -e "@$full_list" -e "$both_keys"

# Check mode on a server still holding the old policy reports the rewrite and leaves it.
write_ansible_policy "$old_policy"
play role --check --diff -e "@$full_list"
reports "$last_play_log" 'openbao_config would rewrite the ansible policy'
recap "$last_play_log" 1
policy_matches "$old_policy" || fail 'check mode must leave the old ansible policy in place'

# The upgrade: the role rewrites the old policy, and the same run reads the keys on its token.
write_ansible_policy "$old_policy"
play role -e "@$full_list" -e "$both_keys"
recap "$last_play_log" 1
changed_task "$last_play_log" 'OpenBao config | Write the ansible policy'
policy_matches "$policy_file" ignoring || fail 'the upgrade must leave the ansible policy equal to ansible-policy.hcl'
for name in tofu-durable tofu-short-lived; do
  no_transit_warning "$last_play_log" "$name"
  [[ $(key_state "$name") == "$good_key" ]] || fail "the upgrade must leave $name unchanged"
done
play role -e "@$full_list" -e "$both_keys"
recap "$last_play_log" 0

# A rule added by hand fails verify, and the next run writes the file's policy back.
api_expect 200 'read the ansible policy before the drift' GET sys/policies/acl/ansible admin_token
python3 - "$work/api.json" "$work/drifted-ansible-policy.hcl" <<'PY'
import json, pathlib, sys
policy = json.load(open(sys.argv[1]))['data']['policy']
pathlib.Path(sys.argv[2]).write_text(policy + 'path "probe/*" { capabilities = ["read"] }\n')
PY
write_ansible_policy "$work/drifted-ansible-policy.hcl"
play_fails policy-drift verify 'the ansible policy must match roles/openbao/files/ansible-policy.hcl' -e "@$full_list" -e "$both_keys"
play role -e "@$full_list" -e "$both_keys"
recap "$last_play_log" 1
changed_task "$last_play_log" 'OpenBao config | Write the ansible policy'
policy_matches "$policy_file" ignoring || fail 'the role must write the drifted ansible policy back'

# A key that leaves the list stays in OpenBao.
play role -e "@$full_list" -e '{"openbao_transit_keys":["tofu-durable"]}'
recap "$last_play_log" 0
[[ $(key_state tofu-short-lived) == "$good_key" ]] || fail 'a key dropped from the list must stay in OpenBao'

# A listed key of another type fails verify, and the role leaves it as it is.
api_expect 200 'make wrongtype as chacha20-poly1305' POST transit/keys/wrongtype admin_token '{"type":"chacha20-poly1305"}'
play_fails wrong-type role 'transit key wrongtype must be aes256-gcm96 with deletion, export and plaintext backup off' \
  -e "@$full_list" -e '{"openbao_transit_keys":["tofu-durable","tofu-short-lived","wrongtype"]}'
[[ $(key_state wrongtype) == 'chacha20-poly1305 False False False' ]] || fail 'the role must not change a listed key of another type'

# Decision 67's guards: the ansible login can't disable transit/, allow a key's deletion, delete a
# key or ask it for a data key.
login ansible TEST_ANSIBLE_PASSWORD ansible_token
api_expect 403 'ansible disabling transit/' DELETE sys/mounts/transit ansible_token
api_expect 403 "ansible allowing tofu-durable's deletion" POST transit/keys/tofu-durable/config ansible_token '{"deletion_allowed":true}'
api_expect 403 'ansible deleting tofu-durable' DELETE transit/keys/tofu-durable ansible_token
api_expect 403 'ansible asking tofu-durable for a data key' POST transit/datakey/plaintext/tofu-durable ansible_token
api_expect 204 'ansible token revoke' POST auth/token/revoke-self ansible_token
[[ $(transit_mount) == transit ]] || fail 'transit/ must survive the guard cases'
[[ $(key_state tofu-durable) == "$good_key" ]] || fail 'tofu-durable must survive the guard cases unchanged'

# Bad or repeated key names are refused before the role signs in.
play_fails bad-key-name role 'openbao_transit_keys names must match ^[a-z][a-z0-9-]*$ and be unique' \
  -e "@$full_list" -e '{"openbao_transit_keys":["Bad_Name"]}'
play_fails duplicate-key role 'openbao_transit_keys names must match ^[a-z][a-z0-9-]*$ and be unique' \
  -e "@$full_list" -e '{"openbao_transit_keys":["tofu-durable","tofu-durable"]}'

# Check mode after the real runs plans nothing, with or without the flag, and no run touched the
# unlisted key.
play role --check --diff -e "@$full_list" -e "$both_keys" -e openbao_make_transit_keys=true
recap "$last_play_log" 0
play role --check --diff -e "@$full_list" -e "$both_keys"
recap "$last_play_log" 0
[[ $(key_state wrongtype) == 'chacha20-poly1305 False False False' ]] || fail 'no run may touch a key the list does not name'
api_expect 200 'read ansible policy after the transit cases' GET sys/policies/acl/ansible admin_token
cp "$work/api.json" "$work/ansible-policy.json"
no_ansible_tokens '3.5a cases'

api_expect 204 'keepbreath0 token revoke' POST auth/token/revoke-self admin_token
logs_clean
printf 'openbao_config driver: all cases passed\n'
