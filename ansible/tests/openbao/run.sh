#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=baotest
home=/home/$user
config=$home/.config/openbao/config
seal=$home/.config/openbao/seal/seal.key
first=$config/first-start.hcl
quadlet=$home/.config/containers/systemd/openbao.container
audit=$home/openbao/logs/audit.log
image=quay.io/openbao/openbao@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'baotest already exists'; fi
if curl -fsS --max-time 2 http://127.0.0.1:8200/ >/dev/null 2>&1; then
  fail '127.0.0.1:8200 is already in use'
fi
# A listener may answer with 404 or 403, so only connection failure means free.
if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8200/ || true) != 000 ]]; then
  fail '127.0.0.1:8200 is already in use'
fi

work=$(mktemp -d)
undo_add 'remove OpenBao driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_install
runner_save_environment
undo_add 'remove driver-created baotest' runner_remove_account
runner_remove_account() { runner_undo_account "$user"; }

printf 'pasta version: %s\n' "$(pasta --version | head -1)"
printf 'podman version: %s\n' "$(podman --version | head -1)"
export TEST_SEAL_KEY TEST_ADMIN_PASSWORD TEST_ANSIBLE_PASSWORD
TEST_SEAL_KEY=$(python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())')
TEST_ADMIN_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
TEST_ANSIBLE_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
play_index=0

play() {
  local name=$1 log
  shift
  play_index=$((play_index + 1))
  log=$work/$name-$play_index.log
  last_play_log=$log
  if ansible-playbook -i localhost, "tests/openbao/$name.yml" "$@" >"$log" 2>&1; then
    return 0
  fi
  if [[ $name == role ]] && id -u "$user" >/dev/null 2>&1; then
    systemctl --user --machine="${user}@" status openbao.service --no-pager >"$work/unit-status.log" 2>&1 || true
    journalctl --no-pager -o short-iso -n 200 "_UID=$(id -u "$user")" >"$work/user-journal.log" 2>&1 || true
    logs_clean
    printf 'OpenBao unit status:\n'
    cat "$work/unit-status.log"
    printf 'OpenBao user journal:\n'
    cat "$work/user-journal.log"
  fi
  tail -35 "$log"
  fail "$name play must pass"
}
recap() {
  local log=$1 expected=$2
  grep -Eq "localhost[[:space:]]+:.*changed=$expected .*failed=0" "$log" || fail "$log recap must have changed=$expected and failed=0"
}
changed_task() {
  local log=$1 title=$2
  python3 - "$log" "$title" <<'PY' || fail "$title must report changed on localhost"
import pathlib, re, sys
log, title = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
assert re.search(r'TASK \[openbao : ' + re.escape(title) + r'\][^\n]*\nchanged: \[localhost\]', log)
PY
}
verify_fails() {
  local label=$1 message=$2 log=$work/$1.log
  if ansible-playbook -i localhost, tests/openbao/verify.yml >"$log" 2>&1; then fail "$label verify unexpectedly passed"; fi
  grep -Fq '"msg": "'"$message"'"' "$log" || { tail -25 "$log"; fail "$label wrong verify failure"; }
}
as_user() {
  HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
    XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
}
restart() {
  as_user systemctl --user daemon-reload
  as_user systemctl --user restart openbao.service
}
health() {
  curl -sS --max-time 3 -o "$work/health.json" -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health
}
healthy() {
  local code
  code=$(health) || return 1
  [[ $code == 200 ]] || return 1
  python3 - "$work/health.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d.get('initialized') is True and d.get('sealed') is False
PY
}
login() {
  local who=$1 variable=$2 expected=$3 response body status
  response=$(python3 - "$variable" <<'PY' | curl -sS --max-time 10 -w '\n%{http_code}' -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:8200/v1/auth/userpass/login/$who"
import json, os, sys
print(json.dumps({'password': os.environ[sys.argv[1]]}))
PY
)
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  [[ $status == 200 ]] || fail "$who login must answer 200"
  LOGIN_RESPONSE="$body" python3 - "$expected" <<'PY' || fail "$who token policies must match"
import json,os,sys
d=json.loads(os.environ['LOGIN_RESPONSE'])
assert set(d['auth']['token_policies']) == set(sys.argv[1].split(','))
PY
  printf -v "login_response_$who" '%s' "$body"
}
capabilities() {
  local who=$1 token response variable=login_response_$1
  token=$(LOGIN_RESPONSE="${!variable}" python3 -c 'import json,os; print(json.loads(os.environ["LOGIN_RESPONSE"])["auth"]["client_token"])')
  response=$(printf 'silent\nshow-error\nrequest = "POST"\nurl = "http://127.0.0.1:8200/v1/sys/capabilities-self"\nheader = "X-Vault-Token: %s"\nheader = "Content-Type: application/json"\ndata = "{\\"paths\\":[\\"sys/policies/acl/example\\",\\"auth/approle/role/example\\",\\"sys/auth/example\\",\\"secret/data/example\\"]}"\n' "$token" | curl --config -)
  CAP_RESPONSE="$response" python3 - "$who" <<'PY' || fail "$who capabilities must match"
import json,os,sys
d=json.loads(os.environ['CAP_RESPONSE']); who=sys.argv[1]
paths=['sys/policies/acl/example','auth/approle/role/example','sys/auth/example','secret/data/example']
if who == 'keepbreath0':
    expected=[{'create','delete','list','read','sudo','update'}]*4
else:
    expected=[{'create','delete','list','read','update'}]*2+[{'create','delete','read','sudo','update'},{'deny'}]
assert all(set(d.get(path,[]))==want for path,want in zip(paths,expected))
PY
}
audit_check() {
  python3 - "$audit" <<'PY' || fail 'audit log must record the ansible loopback login and hide secrets'
import json,os,sys
lines=open(sys.argv[1]).read().splitlines()
assert any((lambda d: d.get('type')=='request' and d.get('request',{}).get('path')=='auth/userpass/login/ansible' and d.get('request',{}).get('remote_address')=='127.0.0.1')(json.loads(line)) for line in lines)
for name in ('TEST_SEAL_KEY','TEST_ADMIN_PASSWORD','TEST_ANSIBLE_PASSWORD'):
    assert all(os.environ[name] not in line for line in lines)
found=any(json.loads(line).get('request',{}).get('path')=='sys/auth/userpass' for line in lines)
print('self-init requests audited: '+('yes' if found else 'no'))
PY
}
logs_clean() {
  python3 - "$work" <<'PY' || fail 'play logs must contain no generated secrets'
import os,pathlib,sys
for path in pathlib.Path(sys.argv[1]).glob('*.log'):
    data=path.read_text()
    for name in ('TEST_SEAL_KEY','TEST_ADMIN_PASSWORD','TEST_ANSIBLE_PASSWORD'):
        assert os.environ[name] not in data, (path,name)
PY
}

if ansible-playbook -i localhost, tests/openbao/missing-user.yml >"$work/missing.log" 2>&1; then fail 'missing openbao_user must fail'; fi
grep -Fq 'missing required arguments: openbao_user' "$work/missing.log" || fail 'missing openbao_user must fail argument validation'
if id -u "$user" >/dev/null 2>&1; then fail 'missing user run created baotest'; fi
[[ ! -e $home ]] || fail 'missing user run created a home'
[[ -z $(find /home -path '*/openbao.container' -print -quit) ]] || fail 'missing user run created a Quadlet'

play role --check --diff
recap "$last_play_log" '[0-9]+'
if id -u "$user" >/dev/null 2>&1; then fail 'check mode created baotest'; fi
[[ ! -e $home ]] || fail 'check mode created a home'
for title in 'OpenBao | Create the account' 'OpenBao | Write the configuration' 'OpenBao | Write the seal key file' 'OpenBao | Write the first-start file' 'OpenBao | Write the Quadlet file'; do
  changed_task "$last_play_log" "$title"
done
logs_clean

if ansible-playbook -i localhost, tests/openbao/missing-admin.yml >"$work/missing-admin.log" 2>&1; then
  fail 'missing first-start administrator password must fail'
fi
grep -Fq '"msg": "openbao_keepbreath0_password is required for OpenBao'"'"'s first start"' "$work/missing-admin.log" || {
  tail -25 "$work/missing-admin.log"
  fail 'missing first-start administrator password must report its own assertion'
}
[[ ! -e $first ]] || fail 'missing administrator password left a first-start file'
runner_undo_account "$user"

[[ $(podman run --rm "$image" id -u openbao) == 100 ]] || fail 'pinned image must run openbao as UID 100'
[[ $(podman run --rm "$image" id -g openbao) == 1000 ]] || fail 'pinned image must run openbao as GID 1000'
podman run --rm "$image" cat /usr/local/bin/docker-entrypoint.sh > "$work/entrypoint"
grep -Fq 'set -- bao server' "$work/entrypoint" || fail 'pinned entrypoint must run the server command'
grep -Fq -- '-config="$BAO_CONFIG_DIR"' "$work/entrypoint" || fail 'pinned entrypoint must load the config directory'
grep -Fq 'if [ -z "$SKIP_CHOWN" ]; then' "$work/entrypoint" || fail 'pinned entrypoint must guard chown'
for path in config logs file; do
  grep -Fq "chown -R openbao:openbao /openbao/$path" "$work/entrypoint" || fail "pinned entrypoint must check $path ownership"
done

play role
recap "$last_play_log" '[0-9]+'
healthy || fail 'first role run must initialize and unseal OpenBao'
[[ ! -e $first ]] || fail 'first-start file must be removed'
[[ $(stat -c %s "$seal") == 44 && $(stat -c %a "$seal") == 600 && $(stat -c %U "$seal") == "$user" ]] || fail 'seal key metadata must match'
[[ $(cat "$seal") == "$TEST_SEAL_KEY" ]] || fail 'seal key contents must match generated key'
[[ $(as_user podman inspect openbao --format '{{.Image}}') == $(as_user podman image inspect "$image" --format '{{.Id}}') ]] || fail 'running OpenBao image ID must match pin'
if [[ ${TEST_FAIL_AFTER_OPENBAO_ROLE:-} == 1 ]]; then fail 'deliberate failure after the openbao role'; fi
login keepbreath0 TEST_ADMIN_PASSWORD default,keepbreath0
login ansible TEST_ANSIBLE_PASSWORD ansible,default
capabilities keepbreath0
capabilities ansible
audit_check

TEST_POISON_ADMIN=1 play role
recap "$last_play_log" 0
play role --check --diff
recap "$last_play_log" 0
restart
for ((second=0; second<60; second++)); do
  if healthy; then break; fi
  sleep 1
done
healthy || fail 'restart must unseal within 60 seconds'
[[ ! -e $first ]] || fail 'restart recreated first-start file'
login keepbreath0 TEST_ADMIN_PASSWORD default,keepbreath0

printf '\n' >> "$seal"
verify_fails key-size 'The seal key file must be exactly 44 bytes'
play role --check --diff
changed_task "$last_play_log" 'OpenBao | Write the seal key file'
play role
[[ $(stat -c %s "$seal") == 44 ]] || fail 'role must restore 44-byte seal key'

printf '%s' "$(python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())')" > "$seal"
restart || true
verify_fails wrong-key 'OpenBao must answer sys/health with 200, initialized and unsealed'
printf '%s' "$TEST_SEAL_KEY" > "$seal"
restart
play verify

printf 'initialize "unexpected" {}\n' > "$first"
verify_fails first-start 'The first-start file must not exist once OpenBao is initialized'
play role
[[ ! -e $first ]] || fail 'role must remove first-start file'

cp "$quadlet" "$work/quadlet.original"
sed -i 's/pasta:--host-lo-to-ns-lo/pasta/' "$quadlet"
restart
verify_fails loopback 'OpenBao must see a loopback client as 127.0.0.1'
cp "$work/quadlet.original" "$quadlet"
restart
play verify
logs_clean
printf 'openbao driver: all cases passed\n'
