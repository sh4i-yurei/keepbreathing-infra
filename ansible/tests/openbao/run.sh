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
runner_remove_account() {
  if ! runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1; then
    cat "$work/account-cleanup.log" >&2
    return 1
  fi
  if grep -vFx 'userdel: baotest mail spool (/var/mail/baotest) not found' "$work/account-cleanup.log" >"$work/unexpected-cleanup.log"; then
    cat "$work/unexpected-cleanup.log" >&2
    return 1
  fi
}

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
assert re.search(r'TASK \[openbao : ' + re.escape(title) + r'\][^\n]*\nchanged: \[localhost\]', log)
PY
}
verify_fails() {
  local label=$1 message=$2 log=$work/$1.log
  if ansible-playbook -i localhost, tests/openbao/verify.yml >"$log" 2>&1; then fail "$label verify unexpectedly passed"; fi
  grep -Fq '"msg": "'"$message"'"' "$log" || { tail -25 "$log"; fail "$label wrong verify failure"; }
}
as_user() {
  (
    cd "$home"
    HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
      XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
  )
}
restart() {
  as_user systemctl --user daemon-reload
  as_user systemctl --user restart openbao.service
}
health() {
  curl -sS --max-time 3 -H 'X-Forwarded-For: 192.0.2.10' -o "$work/health.json" -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health
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
  local who=$1 variable=$2 expected=$3 forwarded=${4:-192.0.2.10} response body status
  response=$(python3 - "$variable" <<'PY' | curl -sS --max-time 10 -w '\n%{http_code}' -H 'Content-Type: application/json' -H "X-Forwarded-For: $forwarded" --data-binary @- "http://127.0.0.1:8200/v1/auth/userpass/login/$who"
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
  response=$(printf 'silent\nshow-error\nrequest = "POST"\nurl = "http://127.0.0.1:8200/v1/sys/capabilities-self"\nheader = "X-Vault-Token: %s"\nheader = "X-Forwarded-For: 192.0.2.10"\nheader = "Content-Type: application/json"\ndata = "{\\"paths\\":[\\"sys/policies/acl/example\\",\\"auth/approle/role/example\\",\\"sys/auth/example\\",\\"secret/data/example\\"]}"\n' "$token" | curl --config -)
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
  local attempt account_journal
  for ((attempt=0; attempt<10; attempt++)); do
    account_journal=$(journalctl --no-pager -o cat "_UID=$(id -u "$user")") || fail 'audit log must record the forwarded ansible login and hide secrets'
    if printf '%s\n' "$account_journal" | python3 -c '
import json,os,sys
lines=sys.stdin.read().splitlines()
for name in ("TEST_SEAL_KEY","TEST_ADMIN_PASSWORD","TEST_ANSIBLE_PASSWORD"):
    assert all(os.environ[name] not in line for line in lines)
entries=[json.loads(line) for line in lines if line.startswith("{")]
assert any(d.get("type")=="request" and d.get("request",{}).get("path")=="auth/userpass/login/ansible" and d.get("request",{}).get("remote_address")=="192.0.2.10" for d in entries)
found=any(d.get("request",{}).get("path")=="sys/auth/userpass" for d in entries)
print("self-init requests audited: "+("yes" if found else "no"))
' 2>/dev/null; then break; fi
    sleep 1
  done
  [[ $attempt -lt 10 ]] || fail 'audit log must record the forwarded ansible login and hide secrets'
}
audit_request_address() {
  local response=$1 expected=$2 attempt
  for ((attempt=0; attempt<10; attempt++)); do
    if as_user podman logs openbao 2>/dev/null | LOGIN_RESPONSE="$response" python3 -c '
import json,os,sys
request_id=json.loads(os.environ["LOGIN_RESPONSE"])["request_id"]
matches=[d for line in sys.stdin if line.startswith("{") if (d:=json.loads(line)).get("type")=="request" and d.get("request",{}).get("id")==request_id]
assert len(matches)==1
assert matches[0].get("request",{}).get("path")=="auth/userpass/login/ansible"
assert matches[0].get("request",{}).get("remote_address")==sys.argv[1]
' "$expected" 2>/dev/null; then return 0; fi
    sleep 1
  done
  fail 'audit request must record the rightmost forwarded address'
}
health_error() {
  local forwarded=$1 expected=$2 code=000 attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if [[ $forwarded == absent ]]; then
      code=$(curl -sS --max-time 3 -o "$work/health-error.json" -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health 2>/dev/null) || code=000
    else
      code=$(curl -sS --max-time 3 -H "X-Forwarded-For: $forwarded" -o "$work/health-error.json" -w '%{http_code}' http://127.0.0.1:8200/v1/sys/health 2>/dev/null) || code=000
    fi
    [[ $code == 000 ]] || break
    sleep 1
  done
  [[ $code == 400 ]] || fail 'health rejection must answer 400'
  python3 - "$work/health-error.json" "$expected" <<'PY' || fail 'health rejection errors must match exactly'
import json,sys
assert json.load(open(sys.argv[1]))['errors']==[sys.argv[2]]
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
if ansible-playbook -i localhost, tests/openbao/missing-self-address.yml >"$work/missing-self-address.log" 2>&1; then fail 'missing openbao_self_address must fail'; fi
grep -Fq 'missing required arguments: openbao_self_address' "$work/missing-self-address.log" || fail 'missing self address must fail argument validation'
if id -u "$user" >/dev/null 2>&1; then fail 'missing self address run created baotest'; fi
[[ ! -e $home ]] || fail 'missing self address run created a home'

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
grep -Fq 'file_path = "stdout"' "$config/openbao.hcl" || fail 'audit device must write to stdout'
if grep -Fq '/openbao/logs' "$config/openbao.hcl"; then fail 'config must not use the logs directory'; fi
grep -Fxq 'LogDriver=journald' "$quadlet" || fail 'Quadlet must use the journald log driver'
if grep -Fq '/openbao/logs' "$quadlet"; then fail 'Quadlet must not mount the logs directory'; fi
# CI can't reproduce the hub's slow first start, so check the limit systemd actually loaded.
start_timeout=$(as_user systemctl --user show openbao.service -p TimeoutStartUSec) || fail 'systemctl show openbao.service must succeed'
if [[ $start_timeout != 'TimeoutStartUSec=15min' ]]; then
  printf '%s\n' "$start_timeout" >&2
  fail 'openbao.service must allow its first start 900 seconds'
fi
python3 - "$quadlet" <<'PY' || fail 'Quadlet [Service] section must set TimeoutStartSec=900 beside Restart=always'
import pathlib, sys
section, service = None, []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('[') and line.endswith(']'):
        section = line
    elif section == '[Service]':
        service.append(line)
assert 'Restart=always' in service and 'TimeoutStartSec=900' in service
PY
[[ ! -e $home/openbao/logs ]] || fail 'role must not create the logs directory'
healthy || fail 'first role run must initialize and unseal OpenBao'
container_stdout=$(as_user podman logs openbao 2>/dev/null) || fail 'podman logs openbao must succeed'
grep -Fq '==> OpenBao server configuration:' <<<"$container_stdout" || fail 'OpenBao standard output must carry its startup banner'
health_error absent 'missing x-forwarded-for header and configured to reject when not present'
[[ ! -e $first ]] || fail 'first-start file must be removed'
[[ $(stat -c %s "$seal") == 44 && $(stat -c %a "$seal") == 600 && $(stat -c %U "$seal") == "$user" ]] || fail 'seal key metadata must match'
[[ $(cat "$seal") == "$TEST_SEAL_KEY" ]] || fail 'seal key contents must match generated key'
container_image=$(as_user podman inspect openbao --format '{{.Image}}') || fail 'running OpenBao image must be inspectable'
pinned_image=$(as_user podman image inspect "$image" --format '{{.Id}}') || fail 'pinned OpenBao image must be inspectable'
[[ -n $container_image && $container_image == "$pinned_image" ]] || fail 'running OpenBao image ID must match pin'
if [[ ${TEST_FAIL_AFTER_OPENBAO_ROLE:-} == 1 ]]; then fail 'deliberate failure after the openbao role'; fi
login keepbreath0 TEST_ADMIN_PASSWORD default,keepbreath0
login ansible TEST_ANSIBLE_PASSWORD ansible,default
audit_request_address "$login_response_ansible" 192.0.2.10
login ansible TEST_ANSIBLE_PASSWORD ansible,default '203.0.113.5, 192.0.2.10'
audit_request_address "$login_response_ansible" 192.0.2.10
capabilities keepbreath0
capabilities ansible
audit_check

sed -i '/^audit "file" "audit" {/,/^}/d' "$config/openbao.hcl"
if grep -Fq 'audit "file" "audit"' "$config/openbao.hcl"; then fail 'audit block must be removed for the negative case'; fi
restart
for ((second=0; second<60; second++)); do
  if healthy; then break; fi
  sleep 1
done
healthy || { journalctl --no-pager -o cat -n 60 "_UID=$(id -u "$user")" | tail -30; fail 'removed audit restart must become healthy'; }
account_journal=$(journalctl --no-pager -o cat "_UID=$(id -u "$user")") || fail 'the account journal must be readable'
grep -Fq 'disabling removed audit device' <<<"$account_journal" || fail 'OpenBao must disable the removed audit device'
verify_fails missing-audit 'OpenBao must record the forwarded client address'
play role
grep -Fq 'file_path = "stdout"' "$config/openbao.hcl" || fail 'role must restore the stdout audit device'
play verify

TEST_POISON_ADMIN=1 play role
recap "$last_play_log" 0
play role --check --diff
recap "$last_play_log" 0
# A stopped user manager with lingering still on: the lingering task is skipped by its
# creates: guard, so the role must start the manager itself before any user-scope call (#139).
systemctl stop "user@$(id -u "$user").service"
play role
changed_task "$last_play_log" "OpenBao | Start the account's user manager"
healthy || fail 'role must bring OpenBao back after starting a stopped user manager'
as_user systemctl --user stop openbao.service
TEST_POISON_ADMIN=1 play role
recap "$last_play_log" '[0-9]+'
python3 - "$last_play_log" <<'PY' || fail 'initialized stopped service must not write the first-start file'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
title = r'TASK \[openbao : OpenBao \| Write the first-start file\]'
assert re.search(title, log)
assert not re.search(title + r'[^\n]*\nchanged: \[localhost\]', log)
PY
[[ ! -e $first ]] || fail 'initialized stopped service left a first-start file'
healthy || fail 'role must restart initialized OpenBao without the administrator password'
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
health_error 192.0.2.10 'client address not authorized for x-forwarded-for and configured to reject connection'
verify_fails loopback 'OpenBao must see a loopback client as 127.0.0.1'
cp "$work/quadlet.original" "$quadlet"
restart
play verify
sed -i '/x_forwarded_for_/d' "$config/openbao.hcl"
restart
verify_fails forwarded-address 'OpenBao must record the forwarded client address'
play role
changed_task "$last_play_log" 'OpenBao | Write the configuration'
recap "$last_play_log" '[0-9]+'
play verify
logs_clean
printf 'openbao driver: all cases passed\n'
