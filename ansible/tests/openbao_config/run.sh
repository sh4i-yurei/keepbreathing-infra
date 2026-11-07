#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=bctest
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'bctest already exists'; fi
if id -u bcnone >/dev/null 2>&1; then fail 'bcnone already exists'; fi
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
printf '%s\n' '{"openbao_approles":[{"name":"testsvc","account":"bctest"},{"name":"othersvc","account":"bctest"}]}' >"$work/consumers.json"

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
save_ids() {
  local name=$1
  cp "/home/bctest/.config/openbao/approle/$name/role-id" "$work/saved-$name-role-id"
  cp "/home/bctest/.config/openbao/approle/$name/secret-id" "$work/saved-$name-secret-id"
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
play role --check --diff -e "@$work/consumers.json"
for name in testsvc othersvc; do
  for message in "openbao_config would write the policy $name" "openbao_config would write the AppRole $name" "openbao_config would issue a secret ID for $name and write its files"; do
    grep -Fq "\"msg\": \"$message\"" "$last_play_log" || fail "missing check-mode message: $message"
  done
done
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
import json, pathlib, sys
name = sys.argv[2]
folder = pathlib.Path('/home/bctest/.config/openbao/approle') / name
role_id = json.load(open(sys.argv[1]))['data']['role_id']
assert (folder / 'role-id').read_text() == role_id
assert folder.stat().st_mode & 0o777 == 0o700
for filename in ('role-id', 'secret-id'):
    path = folder / filename
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.stat().st_uid == folder.stat().st_uid
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
play_fails verify-extra verify 'testsvc must have exactly one secret ID, the one in its file' -e "@$work/consumers.json"
no_ansible_tokens 'extra-ID verify failure'
play role -e "@$work/consumers.json"
play verify -e "@$work/consumers.json"
one_accessor testsvc
no_ansible_tokens 'verify repair'

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

api_expect 204 'keepbreath0 token revoke' POST auth/token/revoke-self admin_token
logs_clean
printf 'openbao_config driver: all cases passed\n'
