#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=bctest
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'bctest already exists'; fi
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

export TEST_SEAL_KEY TEST_ADMIN_PASSWORD TEST_ANSIBLE_PASSWORD
TEST_SEAL_KEY=$(python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())')
TEST_ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
TEST_ANSIBLE_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
play_index=0

# Run a playbook from this folder and require it to pass.
play() {
  local name=$1 log
  shift
  play_index=$((play_index + 1))
  log=$work/$name-$play_index.log
  last_play_log=$log
  if ansible-playbook -i localhost, "tests/openbao_config/$name.yml" "$@" >"$log" 2>&1; then
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

# Call OpenBao's API with the forwarded test address. The token is passed by variable name,
# so its value stays out of every command line. Prints the status; the body is in $work/api.json.
api() {
  local method=$1 path=$2 token_name=${3:-} body=${4:-}
  API_METHOD=$method API_PATH=$path API_TOKEN=${token_name:+${!token_name}} API_BODY=$body \
    python3 - "$work/api.json" <<'PY'
import os, sys, urllib.error, urllib.request
headers = {"X-Forwarded-For": "192.0.2.10"}
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
assert names.count("userpass-ansible") == 0, names
PY
}
logs_clean() {
  python3 - "$work" <<'PY' || fail 'play logs must contain no generated secrets'
import os, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('*.log'):
    data = path.read_text()
    for name in ('TEST_SEAL_KEY', 'TEST_ADMIN_PASSWORD', 'TEST_ANSIBLE_PASSWORD'):
        assert os.environ[name] not in data, (path, name)
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

api_expect 204 'keepbreath0 token revoke' POST auth/token/revoke-self admin_token
logs_clean
printf 'openbao_config driver: all cases passed\n'
