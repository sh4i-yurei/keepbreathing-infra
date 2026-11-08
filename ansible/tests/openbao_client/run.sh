#!/usr/bin/env bash
# The openbao_client driver: installs openbao-read and openbao-podman-secret with their role,
# then runs both as test accounts against a real OpenBao set up by the openbao and
# openbao_config roles, through a stand-in for Tailscale's proxy (OpenBao on the hub decisions
# 16, 17, 58 and 62). Run as root from ansible/.
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
# A listener may answer with 404 or 403, so only connection failure means free.
listening() { [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/" || true) != 000 ]]; }

# Refuse to start over anything this driver makes or removes, and leave it alone.
if id -u bltest >/dev/null 2>&1; then fail 'bltest already exists'; fi
if id -u blother >/dev/null 2>&1; then fail 'blother already exists'; fi
if [[ -e /usr/local/bin/openbao-read || -L /usr/local/bin/openbao-read ]]; then
  fail '/usr/local/bin/openbao-read already exists'
fi
if [[ -e /usr/local/bin/openbao-podman-secret || -L /usr/local/bin/openbao-podman-secret ]]; then
  fail '/usr/local/bin/openbao-podman-secret already exists'
fi
if [[ -e /etc/openbao || -L /etc/openbao ]]; then fail '/etc/openbao already exists'; fi
if listening 8200; then fail '127.0.0.1:8200 is already in use'; fi
if listening 18300; then fail '127.0.0.1:18300 is already in use'; fi

work=$(mktemp -d)
undo_add 'remove openbao_client driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_install
runner_save_environment

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
undo_bltest() { remove_account bltest; }
undo_blother() { remove_account blother; }
undo_add 'remove driver-created bltest' undo_bltest
undo_add 'remove driver-created blother' undo_blother
# The checks above proved neither existed, so whatever is there now is the role's.
undo_client_files() {
  rm -f -- /usr/local/bin/openbao-read /usr/local/bin/openbao-podman-secret
  rm -rf -- /etc/openbao
}
undo_add 'remove /usr/local/bin/openbao-read, /usr/local/bin/openbao-podman-secret and /etc/openbao' undo_client_files

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
# Undo actions run in a subshell, which can't wait for the proxy, so poll until it is gone.
stop_proxy() {
  local attempt
  [[ -n $proxy_pid ]] || return 0
  kill "$proxy_pid" 2>/dev/null || true
  for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$proxy_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$proxy_pid" 2>/dev/null; then
    printf 'proxy stand-in %s is still running\n' "$proxy_pid" >&2
    return 1
  fi
  proxy_pid=
}
undo_add 'stop the proxy stand-in' stop_proxy

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
  if ansible-playbook -i localhost, "tests/openbao_client/$name.yml" "$@" >"$log" 2>&1; then
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
  if ansible-playbook -i localhost, "tests/openbao_client/$name.yml" "$@" >"$log" 2>&1; then
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
import pathlib, sys
log, title = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
# The task's section runs from its header to the next one; --diff puts the diff inside it.
section = log.split('TASK [openbao_client : ' + title + ']', 1)[1].split('\nTASK [', 1)[0]
assert 'changed: [localhost]' in section.splitlines(), section
PY
}
none_installed() {
  local label=$1
  [[ ! -e /usr/local/bin/openbao-read ]] || fail "$label must not install /usr/local/bin/openbao-read"
  [[ ! -e /usr/local/bin/openbao-podman-secret ]] || fail "$label must not install /usr/local/bin/openbao-podman-secret"
  [[ ! -e /etc/openbao ]] || fail "$label must not create /etc/openbao"
}
installed() {
  [[ $(stat -c '%U:%G %a %F' /etc/openbao) == 'root:root 755 directory' ]] || fail '/etc/openbao must be root:root 0755'
  [[ $(stat -c '%U:%G %a %F' /usr/local/bin/openbao-read) == 'root:root 755 regular file' ]] || fail 'openbao-read must be root:root 0755'
  [[ $(stat -c '%U:%G %a %F' /etc/openbao/client.json) == 'root:root 644 regular file' ]] || fail 'client.json must be root:root 0644'
  cmp -s roles/openbao_client/files/openbao-read.py /usr/local/bin/openbao-read || fail 'openbao-read must be the role file'
  [[ $(stat -c '%U:%G %a %F' /usr/local/bin/openbao-podman-secret) == 'root:root 755 regular file' ]] || fail 'openbao-podman-secret must be root:root 0755'
  cmp -s roles/openbao_client/files/openbao-podman-secret.py /usr/local/bin/openbao-podman-secret || fail 'openbao-podman-secret must be the role file'
  python3 - <<'PY' || fail 'client.json must read {"address": "http://127.0.0.1:18300"}'
import json
assert json.load(open('/etc/openbao/client.json')) == {"address": "http://127.0.0.1:18300"}
PY
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
healthy() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    [[ $(api GET sys/health) == 200 ]] && return 0
    sleep 1
  done
  return 1
}

# Run openbao-read as an account from /, which every account can enter. Its output goes to
# files that logs_clean also checks, and its exit status to $helper_status.
helper_index=0
helper() {
  local account=$1 path=$2
  helper_index=$((helper_index + 1))
  helper_out=$work/helper-$helper_index-out.log
  helper_err=$work/helper-$helper_index-err.log
  helper_status=0
  (cd / && runuser -u "$account" -- /usr/local/bin/openbao-read "$path") >"$helper_out" 2>"$helper_err" || helper_status=$?
}
helper_report() {
  printf 'status %s\nstdout:\n%s\nstderr:\n%s\n' "$helper_status" "$(cat "$helper_out")" "$(cat "$helper_err")" >&2
}
# Require an exit status, exact standard output with no newline, and exact standard error.
helper_exact() {
  local label=$1 status=$2 output=$3 errors=$4
  [[ $helper_status == "$status" ]] || { helper_report; fail "$label must exit $status"; }
  printf '%s' "$output" | cmp -s - "$helper_out" || { helper_report; fail "$label must print exactly '$output' with no newline"; }
  if [[ -z $errors ]]; then
    [[ ! -s $helper_err ]] || { helper_report; fail "$label must write nothing to standard error"; }
  else
    printf '%s\n' "$errors" | cmp -s - "$helper_err" || { helper_report; fail "$label must write exactly one line: $errors"; }
  fi
}
# Require exit 1, no output and one error line that starts with the given text.
helper_fails_with() {
  local label=$1 prefix=$2
  [[ $helper_status == 1 ]] || { helper_report; fail "$label must exit 1"; }
  [[ ! -s $helper_out ]] || { helper_report; fail "$label must print nothing"; }
  [[ $(wc -l <"$helper_err") == 1 && $(head -1 "$helper_err") == "$prefix"* ]] || {
    helper_report
    fail "$label must write one line starting: $prefix"
  }
}
# Run openbao-podman-secret as an account from /, the way Podman runs its shell driver: SECRET_ID
# set unless it is empty, as for list, and the given text on standard input with no newline. The
# results land where helper_exact reads them.
podman_secret_index=0
podman_secret() {
  local account=$1 secret_id=$2 command=$3 input=${4-}
  local -a environment=()
  podman_secret_index=$((podman_secret_index + 1))
  helper_out=$work/podman-secret-$podman_secret_index-out.log
  helper_err=$work/podman-secret-$podman_secret_index-err.log
  helper_status=0
  if [[ -n $secret_id ]]; then environment=("SECRET_ID=$secret_id"); fi
  printf '%s' "$input" |
    (cd / && runuser -u "$account" -- /usr/bin/env -u SECRET_ID "${environment[@]}" /usr/local/bin/openbao-podman-secret "$command") \
    >"$helper_out" 2>"$helper_err" || helper_status=$?
}

# No helper token may be left, and no ansible token. The driver revokes its own keepbreath0
# token only after it counts.
no_leftover_tokens() {
  ADMIN_TOKEN=$admin_token python3 - <<'PY' || fail 'a helper or ansible token was left behind'
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
print("token display names left:", sorted(names))
assert not ({"approle", "userpass-ansible"} & set(names)), names
PY
}
logs_clean() {
  python3 - "$work" <<'PY' || fail 'play logs and helper output must contain no generated secret, role ID or secret ID'
import os, pathlib, sys
work = pathlib.Path(sys.argv[1])
secrets = [os.environ[name] for name in ('TEST_SEAL_KEY', 'TEST_ADMIN_PASSWORD', 'TEST_ANSIBLE_PASSWORD')]
secrets += [path.read_text() for path in work.glob('*-id')]
assert len(secrets) == 7, len(secrets)
logs = sorted(work.glob('*.log'))
assert len(logs) > 10, logs
for path in logs:
    data = path.read_text()
    for secret in secrets:
        assert secret not in data, path
PY
}

# Check mode on a machine where nothing exists reports every file and creates nothing.
play role --check --diff
recap "$last_play_log" 4
changed_task "$last_play_log" 'OpenBao client | Install the openbao-read helper'
changed_task "$last_play_log" 'OpenBao client | Write the address file'
none_installed 'check mode'

# The real run installs them all, a second run and a check run change nothing.
play role
recap "$last_play_log" 4
installed
printf '%s\n' '{"address": "http://127.0.0.1:18300"}' | cmp -s - /etc/openbao/client.json || fail 'client.json must hold exactly one line of JSON'
play role
recap "$last_play_log" 0
play role --check --diff
recap "$last_play_log" 0

# The verify task file catches a wrong mode and a file without an address; the role repairs both.
chmod 0600 /etc/openbao/client.json
play_fails verify-mode verify '/etc/openbao (0755), /usr/local/bin/openbao-read (0755), /usr/local/bin/openbao-podman-secret (0755) and /etc/openbao/client.json (0644) must exist and be owned by root'
play role
recap "$last_play_log" 1
printf '%s\n' '{"server": "http://127.0.0.1:18300"}' >/etc/openbao/client.json
play_fails verify-address verify '/etc/openbao/client.json must parse with an address'
play role
recap "$last_play_log" 1
play verify
installed

# OpenBao, its mounts and two consumers, each with its own account.
useradd -m blother
play openbao
healthy || fail 'the openbao role must start OpenBao'
login_body=$(python3 -c 'import json,os; print(json.dumps({"password": os.environ["TEST_ADMIN_PASSWORD"]}))')
api_expect 200 'keepbreath0 login' POST auth/userpass/login/keepbreath0 '' "$login_body"
admin_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auth"]["client_token"])' "$work/api.json")
play config
for pair in clientsvc:bltest othersvc:blother; do
  name=${pair%%:*} account=${pair##*:}
  for file in role-id secret-id; do
    cp "/home/$account/.config/openbao/approle/$name/$file" "$work/$name-$file"
  done
done
api_expect 200 'clientsvc probe write' POST secret/data/clientsvc/probe admin_token '{"data":{"value":"clientsvc-probe"}}'
api_expect 200 'othersvc probe write' POST secret/data/othersvc/probe admin_token '{"data":{"value":"othersvc-probe"}}'

# Through the proxy as the hub's address, each account reads its own consumer and only that.
start_proxy 192.0.2.10
helper bltest clientsvc/probe
helper_exact 'bltest reading clientsvc/probe' 0 clientsvc-probe ''
helper bltest othersvc/probe
helper_exact 'bltest reading othersvc/probe' 1 '' 'openbao-read: no AppRole files for othersvc in /home/bltest/.config/openbao/approle/othersvc'
helper blother othersvc/probe
helper_exact 'blother reading othersvc/probe' 0 othersvc-probe ''
helper bltest clientsvc/missing
helper_fails_with 'bltest reading clientsvc/missing' 'openbao-read: reading clientsvc/missing failed: 404'
printf 'never-written path: %s\n' "$(cat "$helper_err")"
stop_proxy

# From an address outside the AppRole's binding, the sign-in is refused.
start_proxy 198.51.100.7
helper bltest clientsvc/probe
helper_fails_with 'bltest reading clientsvc/probe from 198.51.100.7' 'openbao-read: sign-in as clientsvc failed: 400 source address "198.51.100.7" unauthorized by CIDR restrictions on the role'
printf 'unbound address: %s\n' "$(cat "$helper_err")"
stop_proxy

# Podman's secret driver as bltest keeps only the path and looks the value up through the real
# openbao-read, at the hub's address again (decision 62). The ID is a fixed Podman-shaped one.
podman_id=a134b9626fd9d45bfbfe8df7d
podman_secrets=/home/bltest/.config/openbao/podman-secrets
start_proxy 192.0.2.10
podman_secret bltest "$podman_id" store clientsvc/probe
helper_exact 'bltest storing clientsvc/probe' 0 '' ''
[[ $(stat -c '%U %a %F' "$podman_secrets") == 'bltest 700 directory' ]] || fail "$podman_secrets must be bltest's with mode 0700"
[[ $(stat -c '%U %a %F' "$podman_secrets/$podman_id") == 'bltest 600 regular file' ]] || fail "the secret's file must be bltest's with mode 0600"
printf '%s' clientsvc/probe | cmp -s - "$podman_secrets/$podman_id" || fail "the secret's file must hold exactly clientsvc/probe"
podman_secret bltest "$podman_id" lookup
helper_exact 'bltest looking up its Podman secret' 0 clientsvc-probe ''
podman_secret bltest '' list
helper_exact 'bltest listing its Podman secrets' 0 "$podman_id"$'\n' ''
podman_secret bltest "$podman_id" delete
helper_exact 'bltest deleting its Podman secret' 0 '' ''
podman_secret bltest "$podman_id" delete
helper_exact 'bltest deleting its Podman secret again' 0 '' ''
[[ ! -e $podman_secrets/$podman_id ]] || fail "delete must remove the secret's file"
podman_secret bltest "$podman_id" lookup
helper_exact 'bltest looking up a deleted Podman secret' 1 '' "openbao-podman-secret: no secret stored for $podman_id"
printf 'deleted Podman secret: %s\n' "$(cat "$helper_err")"
stop_proxy

no_leftover_tokens
api_expect 204 'keepbreath0 token revoke' POST auth/token/revoke-self admin_token
logs_clean
printf 'openbao_client driver: all cases passed\n'
