#!/usr/bin/env bash
# The openbao_client driver: installs openbao-read and openbao-podman-secret with their role,
# then runs both as test accounts against a real OpenBao set up by the openbao and
# openbao_config roles, through a stand-in for Tailscale's proxy (OpenBao on the hub decisions
# 16, 17, 58 and 62). Run as root from ansible/.
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
# The morning digest's files, its drop-in holding the service, the drop-in's permit and the timer's
# stamp (OpenBao on the hub 4.5).
digest_hold=/run/systemd/system/ticket-digest.service.d/driver-hold.conf
digest_permit=/run/ticket-digest-driver-permit
digest_paths=(/usr/local/libexec/ticket-digest /etc/ticket-digest.json
  /etc/systemd/system/ticket-digest.service /etc/systemd/system/ticket-digest.timer
  "$digest_hold" "$digest_permit" /var/lib/systemd/timers/stamp-ticket-digest.timer)
# A listener may answer with 404 or 403, so only connection failure means free.
listening() { [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/" || true) != 000 ]]; }

# Refuse to start over anything this driver makes or removes, and leave it alone.
if id -u bltest >/dev/null 2>&1; then fail 'bltest already exists'; fi
if id -u blother >/dev/null 2>&1; then fail 'blother already exists'; fi
if id -u tbclient >/dev/null 2>&1; then fail 'tbclient already exists'; fi
if [[ -e /usr/local/bin/openbao-read || -L /usr/local/bin/openbao-read ]]; then
  fail '/usr/local/bin/openbao-read already exists'
fi
if [[ -e /usr/local/bin/openbao-podman-secret || -L /usr/local/bin/openbao-podman-secret ]]; then
  fail '/usr/local/bin/openbao-podman-secret already exists'
fi
if [[ -e /etc/openbao || -L /etc/openbao ]]; then fail '/etc/openbao already exists'; fi
if listening 8200; then fail '127.0.0.1:8200 is already in use'; fi
if listening 18300; then fail '127.0.0.1:18300 is already in use'; fi
if listening 18083; then fail '127.0.0.1:18083 is already in use'; fi
for path in "${digest_paths[@]}"; do
  if [[ -e $path || -L $path ]]; then fail "$path already exists"; fi
done
if listening 18400; then fail '127.0.0.1:18400 is already in use'; fi
if listening 18401; then fail '127.0.0.1:18401 is already in use'; fi

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
undo_tbclient() { remove_account tbclient; }
undo_add 'remove driver-created bltest' undo_bltest
undo_add 'remove driver-created blother' undo_blother
undo_add 'remove driver-created tbclient' undo_tbclient
# The checks above proved neither existed, so whatever is there now is the role's.
undo_client_files() {
  rm -f -- /usr/local/bin/openbao-read /usr/local/bin/openbao-podman-secret
  rm -rf -- /etc/openbao
}
undo_add 'remove /usr/local/bin/openbao-read, /usr/local/bin/openbao-podman-secret and /etc/openbao' undo_client_files
# Registered after the accounts' undo, so it runs first: the timer is gone before tbclient is. The
# disable is quiet, because the job requires the driver's success line to be its last.
undo_digest() {
  if [[ -e /etc/systemd/system/ticket-digest.timer ]]; then
    systemctl disable --now --quiet ticket-digest.timer
  fi
  rm -f -- "${digest_paths[@]}"
  if [[ -d ${digest_hold%/*} ]]; then rmdir -- "${digest_hold%/*}"; fi
  systemctl daemon-reload
  if [[ $(systemctl show ticket-digest.service -p ActiveState --value) == failed ]]; then
    systemctl reset-failed ticket-digest.service
  fi
}
undo_add 'remove the morning digest' undo_digest

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
# digest_standin.py, GitHub on 127.0.0.1:18400 and ntfy on 127.0.0.1:18401, for the digest's run.
standin_pid=
stop_digest_standin() {
  local attempt
  [[ -n $standin_pid ]] || return 0
  kill "$standin_pid" 2>/dev/null || true
  for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$standin_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$standin_pid" 2>/dev/null; then
    printf 'digest stand-in %s is still running\n' "$standin_pid" >&2
    return 1
  fi
  standin_pid=
}
undo_add 'stop the digest stand-in' stop_digest_standin

openbao_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["openbao_image"])')
export TEST_OPENBAO_IMAGE=$openbao_image
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

# Run a command that calls openbao-read from /, which every account can enter. Its output goes
# to files that logs_clean also checks, and its exit status to $helper_status.
helper_index=0
helper_run() {
  helper_index=$((helper_index + 1))
  helper_out=$work/helper-$helper_index-out.log
  helper_err=$work/helper-$helper_index-err.log
  helper_status=0
  (cd / && "$@") >"$helper_out" 2>"$helper_err" || helper_status=$?
}
# Run openbao-read as an account.
helper() {
  local account=$1 path=$2
  helper_run runuser -u "$account" -- /usr/local/bin/openbao-read "$path"
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
# results land where helper_exact reads them. With --unshare first, it runs through podman unshare,
# inside the account's rootless user namespace, as Podman itself runs the driver.
podman_secret_index=0
podman_secret() {
  local -a through=() environment=()
  if [[ $1 == --unshare ]]; then
    through=(env "XDG_RUNTIME_DIR=/run/user/$(id -u "$2")" podman unshare)
    shift
  fi
  local account=$1 secret_id=$2 command=$3 input=${4-}
  podman_secret_index=$((podman_secret_index + 1))
  helper_out=$work/podman-secret-$podman_secret_index-out.log
  helper_err=$work/podman-secret-$podman_secret_index-err.log
  helper_status=0
  if [[ -n $secret_id ]]; then environment=("SECRET_ID=$secret_id"); fi
  printf '%s' "$input" |
    (cd / && runuser -u "$account" -- "${through[@]}" /usr/bin/env -u SECRET_ID "${environment[@]}" /usr/local/bin/openbao-podman-secret "$command") \
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
  python3 - "$work" "$patterns" <<'PY' || fail 'play logs and helper output must contain no generated secret, role ID, secret ID or test value'
import os, pathlib, sys
work, patterns = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
secrets = [os.environ[name] for name in ('TEST_SEAL_KEY', 'TEST_ADMIN_PASSWORD', 'TEST_ANSIBLE_PASSWORD')]
secrets += [path.read_text() for path in work.glob('*-id')]
# The two Podman test values, read from their pattern files so no command line holds them.
secrets += [(patterns / name).read_text().rstrip('\n') for name in ('pod-one', 'pod-two')]
# The receiver's App key, one entry per base64 body line, so a log holding any one line is caught.
key_lines = (patterns / 'app-key-body').read_text().splitlines()
assert len(key_lines) > 20, len(key_lines)
secrets += key_lines
assert len(secrets) == 11 + len(key_lines), len(secrets)
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
# The same verify catches the driver program with the wrong mode; the role repairs it.
chmod 0644 /usr/local/bin/openbao-podman-secret
play_fails verify-driver-mode verify '/etc/openbao (0755), /usr/local/bin/openbao-read (0755), /usr/local/bin/openbao-podman-secret (0755) and /etc/openbao/client.json (0644) must exist and be owned by root'
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
# tbclient is made the way hub.yml makes the band's account: ticket_band's account part runs
# before openbao_config, which needs the account to exist (OpenBao on the hub decisions 55 and 75).
play ticket-band-account
play config
for pair in clientsvc:bltest othersvc:blother tbsvc:tbclient; do
  name=${pair%%:*} account=${pair##*:}
  for file in role-id secret-id; do
    cp "/home/$account/.config/openbao/approle/$name/$file" "$work/$name-$file"
  done
done
for file in role-id secret-id; do
  [[ $(stat -c '%U %a %F' "/home/tbclient/.config/openbao/approle/tbsvc/$file") == 'tbclient 600 regular file' ]] ||
    fail "tbsvc's $file must be tbclient's regular file with mode 0600"
done
[[ -f /home/tbclient/.config/containers/containers.conf.d/openbao.conf ]] ||
  fail "ticket_band's account part must write tbclient's openbao.conf"
api_expect 200 'clientsvc probe write' POST secret/data/clientsvc/probe admin_token '{"data":{"value":"clientsvc-probe"}}'
api_expect 200 'othersvc probe write' POST secret/data/othersvc/probe admin_token '{"data":{"value":"othersvc-probe"}}'
api_expect 200 'tbsvc probe write' POST secret/data/tbsvc/probe admin_token '{"data":{"value":"tbsvc-probe"}}'

# Through the proxy as the hub's address, each account reads its own consumer and only that.
start_proxy 192.0.2.10
helper bltest clientsvc/probe
helper_exact 'bltest reading clientsvc/probe' 0 clientsvc-probe ''
helper bltest othersvc/probe
helper_exact 'bltest reading othersvc/probe' 1 '' 'openbao-read: no AppRole files for othersvc in /home/bltest/.config/openbao/approle/othersvc'
helper blother othersvc/probe
helper_exact 'blother reading othersvc/probe' 0 othersvc-probe ''
helper tbclient tbsvc/probe
helper_exact 'tbclient reading tbsvc/probe' 0 tbsvc-probe ''
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

# Inside Podman's rootless user namespace bltest is uid 0, and a systemd unit can carry another
# HOME; openbao-read still finds bltest's own home in both (decisions 58 and 63).
start_proxy 192.0.2.10
helper_run runuser -u bltest -- env "XDG_RUNTIME_DIR=/run/user/$(id -u bltest)" podman unshare /usr/local/bin/openbao-read clientsvc/probe
helper_exact 'bltest reading clientsvc/probe through podman unshare' 0 clientsvc-probe ''
helper_run systemd-run --uid=bltest --setenv=HOME=/nonexistent --wait --pipe --quiet /usr/local/bin/openbao-read clientsvc/probe
helper_exact 'a systemd-run unit as bltest with HOME=/nonexistent reading clientsvc/probe' 0 clientsvc-probe ''

# Podman's secret driver as bltest keeps only the path and looks the value up through the real
# openbao-read, at the hub's address again (decision 62). The ID is a fixed Podman-shaped one.
podman_id=a134b9626fd9d45bfbfe8df7d
podman_secrets=/home/bltest/.config/openbao/podman-secrets
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

# Inside Podman's rootless user namespace bltest is uid 0; the driver program still keeps its
# paths in bltest's own home, with bltest's modes, and looks the value up (decision 63).
rmdir "$podman_secrets"
podman_secret --unshare bltest "$podman_id" store clientsvc/probe
helper_exact 'bltest storing clientsvc/probe through podman unshare' 0 '' ''
[[ $(stat -c '%U %a %F' "$podman_secrets") == 'bltest 700 directory' ]] || fail "$podman_secrets made through podman unshare must be bltest's with mode 0700"
[[ $(stat -c '%U %a %F' "$podman_secrets/$podman_id") == 'bltest 600 regular file' ]] || fail "the secret's file stored through podman unshare must be bltest's with mode 0600"
printf '%s' clientsvc/probe | cmp -s - "$podman_secrets/$podman_id" || fail "the secret's file stored through podman unshare must hold exactly clientsvc/probe"
podman_secret --unshare bltest "$podman_id" lookup
helper_exact 'bltest looking up its Podman secret through podman unshare' 0 clientsvc-probe ''
podman_secret --unshare bltest '' list
helper_exact 'bltest listing its Podman secrets through podman unshare' 0 "$podman_id"$'\n' ''
podman_secret --unshare bltest "$podman_id" delete
helper_exact 'bltest deleting its Podman secret through podman unshare' 0 '' ''
[[ ! -e $podman_secrets/$podman_id ]] || fail "delete through podman unshare must remove the secret's file"
stop_proxy

# An account takes its containers' secrets from OpenBao (decision 72). podman-account makes
# openbao-podman-secret blother's default Podman secret driver, podman-secret keeps only a path
# in a Podman secret, and a Quadlet unit reads the value when it starts. Lookups reach OpenBao
# at the hub's address.
start_proxy 192.0.2.10
blother_uid=$(id -u blother)
bltest_uid=$(id -u bltest)
openbao_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["openbao_image"])')
# Run a command as an account from /, with its run directory, the way its user manager would.
as_account() {
  local account=$1
  shift
  (
    cd /
    HOME="/home/$account" USER="$account" LOGNAME="$account" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$account")" runuser -u "$account" -- "$@"
  )
}
# Count a pipe's lines matching a pattern file; no match is a count of 0, not a failure.
count_matching() { grep -cF -f "$1" || [[ $? == 1 ]]; }
# Print the files under the given folders holding a pattern file's value, skipping sockets and
# FIFOs.
files_holding() {
  local pattern=$1
  shift
  grep -rlsF -D skip -f "$pattern" "$@" || true
}
# OpenBao's reads of one path, from its audit log, which is the openbao container's output.
audit_reads() {
  as_account bltest podman logs openbao 2>/dev/null | AUDIT_PATH=$1 python3 -c '
import json, os, sys
count = 0
for line in sys.stdin:
    if not line.startswith("{"):
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    request = entry.get("request", {})
    if (entry.get("type") == "request" and request.get("operation") == "read"
            and request.get("path") == os.environ["AUDIT_PATH"]):
        count += 1
print(count)
'
}
secret_changed() {
  local log=$1 expected=$2
  grep -Fq "\"openbao_client_secret_changed\": $expected" "$log" || {
    tail -40 "$log"
    fail "$log must set openbao_client_secret_changed to $expected"
  }
}
podman_secret_play() {
  local path=$1
  shift
  play podman-secret -e openbao_client_podman_account=blother -e openbao_client_secret_name=appkey \
    -e "openbao_client_secret_path=$path" "$@"
}
appkey_field() { as_account blother podman secret inspect --format "{{$1}}" appkey; }
unit_state() { as_account blother systemctl --user is-active podread.service || true; }
blother_journal_count() { journalctl --no-pager -o cat "_UID=$blother_uid" | grep -cFx "$1" || [[ $? == 1 ]]; }
wait_for_journal() {
  local line=$1 count=$2 attempt
  for ((attempt=0; attempt<60; attempt++)); do
    (( $(blother_journal_count "$line") >= count )) && return 0
    sleep 1
  done
  journalctl --no-pager -o cat "_UID=$blother_uid" | tail -30
  fail "blother's journal must have the line $line $count times"
}

# The two test values live only in OpenBao and in pattern files outside /tmp and every home,
# which grep -F -f reads, so no command line and no file the cases search ever holds them.
patterns=$(mktemp -d /run/openbao-client-patterns.XXXXXX)
undo_add 'remove the test value patterns' undo_patterns
undo_patterns() { rm -rf -- "$patterns"; }
pod_one_value=pod-one-value-1
pod_two_value=pod-two-value-longer-2
printf '%s\n' "$pod_one_value" >"$patterns/pod-one"
printf '%s\n' "$pod_two_value" >"$patterns/pod-two"
printf '%s\n%s\n' "$pod_one_value" "$pod_two_value" >"$patterns/both"
api_expect 200 'othersvc pod-one write' POST secret/data/othersvc/pod-one admin_token "{\"data\":{\"value\":\"$pod_one_value\"}}"
api_expect 200 'othersvc pod-two write' POST secret/data/othersvc/pod-two admin_token "{\"data\":{\"value\":\"$pod_two_value\"}}"

# blother's own role would turn on lingering and write its transient storage before its first
# podman command.
loginctl enable-linger blother
for ((attempt=0; attempt<120; attempt++)); do
  [[ -S /run/user/$blother_uid/bus ]] && break
  sleep 0.5
done
[[ -S /run/user/$blother_uid/bus ]] || fail "blother's user manager must start"
as_account blother mkdir -p -m 0700 /home/blother/.config/containers
printf '[storage]\ndriver = "overlay"\ntransient_store = true\n' |
  as_account blother tee /home/blother/.config/containers/storage.conf >/dev/null
as_account blother podman pull -q "$openbao_image" >/dev/null

# Check mode for an account that doesn't exist yet reports what it would do and makes nothing.
if id -u blnone >/dev/null 2>&1; then fail 'blnone already exists'; fi
play podman-account --check --diff -e openbao_client_podman_account=blnone
recap "$last_play_log" 1
grep -Fq "\"msg\": \"openbao_client would make blnone's default Podman secret driver openbao-podman-secret\"" "$last_play_log" ||
  fail 'podman-account in check mode must report the default driver it would make for blnone'
play podman-secret --check --diff -e openbao_client_podman_account=blnone -e openbao_client_secret_name=appkey \
  -e openbao_client_secret_path=othersvc/pod-one
recap "$last_play_log" 1
grep -Fq '"msg": "openbao_client would create the Podman secret appkey for blnone"' "$last_play_log" ||
  fail 'podman-secret in check mode must report the secret it would create for blnone'
secret_changed "$last_play_log" true
if id -u blnone >/dev/null 2>&1; then fail 'check mode must not create blnone'; fi
[[ ! -e /home/blnone ]] || fail 'check mode must not create /home/blnone'

# podman-account writes the shell driver as blother's drop-in, as blother, and changes nothing
# the second time.
play podman-account -e openbao_client_podman_account=blother
changed_task "$last_play_log" 'OpenBao client | Write the OpenBao secret driver drop-in'
drop_in_folder=/home/blother/.config/containers/containers.conf.d
[[ $(stat -c '%U %a %F' "$drop_in_folder") == 'blother 700 directory' ]] || fail "$drop_in_folder must be blother's with mode 0700"
[[ $(stat -c '%U %a %F' "$drop_in_folder/openbao.conf") == 'blother 600 regular file' ]] || fail "openbao.conf must be blother's with mode 0600"
cmp -s - "$drop_in_folder/openbao.conf" <<'EOF' || fail 'openbao.conf must hold exactly the shell driver and its four commands'
# Written by openbao_client (OpenBao on the hub decision 72). Every Podman secret in this
# account keeps only an OpenBao path, and openbao-podman-secret looks the value up.
[secrets]
driver = "shell"

[secrets.opts]
delete = "/usr/local/bin/openbao-podman-secret delete"
list = "/usr/local/bin/openbao-podman-secret list"
lookup = "/usr/local/bin/openbao-podman-secret lookup"
store = "/usr/local/bin/openbao-podman-secret store"
EOF
play podman-account -e openbao_client_podman_account=blother
recap "$last_play_log" 0

# bltest's OpenBao container runs on persistent storage, so bltest is refused and given nothing.
play_fails podman-account-persistent podman-account \
  "bltest must use Podman's transient store, with its run root under /run/user/$bltest_uid/, before it takes secrets from OpenBao" \
  -e openbao_client_podman_account=bltest
[[ ! -e /home/bltest/.config/containers/containers.conf.d ]] || fail 'a refused account must get no containers.conf.d'

# A wrong secret name or path is refused before anything is made.
play_fails podman-secret-name podman-secret 'openbao_client_secret_name must match ^[a-z][a-z0-9-]*$' \
  -e openbao_client_podman_account=blother -e openbao_client_secret_name=App-Key -e openbao_client_secret_path=othersvc/pod-one
play_fails podman-secret-path podman-secret 'openbao_client_secret_path must be <consumer>/<name>, each matching ^[a-z][a-z0-9-]*$' \
  -e openbao_client_podman_account=blother -e openbao_client_secret_name=appkey -e openbao_client_secret_path=othersvc
[[ -z $(as_account blother podman secret ls --quiet) ]] || fail 'a refused name or path must create no Podman secret'
[[ ! -e /home/blother/.config/openbao/podman-secrets ]] || fail 'a refused name or path must store no path'

# Four runs: create, unchanged, a new path, unchanged. None reads a value from OpenBao.
reads_one=$(audit_reads secret/data/othersvc/pod-one)
reads_two=$(audit_reads secret/data/othersvc/pod-two)
podman_secret_play othersvc/pod-one
recap "$last_play_log" 1
secret_changed "$last_play_log" true
podman_secret_play othersvc/pod-one
recap "$last_play_log" 0
secret_changed "$last_play_log" false
podman_secret_play othersvc/pod-two
recap "$last_play_log" 1
secret_changed "$last_play_log" true
podman_secret_play othersvc/pod-two
recap "$last_play_log" 0
secret_changed "$last_play_log" false
appkey_secret=$(appkey_field .ID)
mapping_folder=/home/blother/.config/openbao/podman-secrets
[[ $(stat -c '%U %a %F' "$mapping_folder/$appkey_secret") == 'blother 600 regular file' ]] || fail "appkey's mapping file must be blother's with mode 0600"
printf '%s' othersvc/pod-two | cmp -s - "$mapping_folder/$appkey_secret" || fail "appkey's mapping file must hold exactly othersvc/pod-two"
[[ $(audit_reads secret/data/othersvc/pod-one) == "$reads_one" ]] || fail 'podman-secret must never read othersvc/pod-one from OpenBao'
[[ $(audit_reads secret/data/othersvc/pod-two) == "$reads_two" ]] || fail 'podman-secret must never read othersvc/pod-two from OpenBao'

# Check mode after the real runs changes nothing.
play podman-account --check --diff -e openbao_client_podman_account=blother
recap "$last_play_log" 0
podman_secret_play othersvc/pod-two --check --diff
recap "$last_play_log" 0
secret_changed "$last_play_log" false

# A missing mapping file is replaced under a new ID holding the path.
rm -- "${mapping_folder:?}/$appkey_secret"
podman_secret_play othersvc/pod-two
recap "$last_play_log" 1
secret_changed "$last_play_log" true
replaced_secret=$(appkey_field .ID)
[[ $replaced_secret != "$appkey_secret" ]] || fail 'a missing mapping file must give appkey a new ID'
printf '%s' othersvc/pod-two | cmp -s - "$mapping_folder/$replaced_secret" || fail "appkey's new mapping file must hold exactly othersvc/pod-two"

# A secret made by hand with the file driver is removed through it and made again with shell.
# The file driver keeps each secret's data base64-encoded in secretsdata.json, so the path is
# looked for both as it is and encoded.
file_driver_folder=/home/blother/.local/share/containers/storage/secrets/filedriver
file_driver_path=$(printf '%s' othersvc/pod-one | base64)
as_account blother podman secret rm appkey >/dev/null
printf '%s' othersvc/pod-one | as_account blother podman secret create --driver file appkey - >/dev/null
[[ $(appkey_field .Spec.Driver.Name) == file ]] || fail 'the hand-made appkey must use the file driver'
[[ -n $(grep -rlsF "$file_driver_path" "$file_driver_folder" || true) ]] || fail 'the file driver must hold the hand-made path'
podman_secret_play othersvc/pod-one
recap "$last_play_log" 2
changed_task "$last_play_log" 'OpenBao client | Remove the Podman secret made with another driver'
secret_changed "$last_play_log" true
[[ $(appkey_field .Spec.Driver.Name) == shell ]] || fail 'appkey must be made again with the shell driver'
[[ -z $(grep -rlsF -e othersvc/pod-one -e "$file_driver_path" "$file_driver_folder" || true) ]] || fail 'the file driver must keep no copy of the path'
podman_secret_play othersvc/pod-one
recap "$last_play_log" 0
secret_changed "$last_play_log" false

# A Quadlet unit reads appkey's value from OpenBao when it starts and prints only its length.
unit_folder=/home/blother/.config/containers/systemd
as_account blother mkdir -p -m 0700 "$unit_folder"
printf '%s\n' '[Container]' "Image=$openbao_image" 'Entrypoint=/bin/sh' \
  'Exec=-c "echo len=$${#MYSECRET}; sleep 300"' 'Secret=appkey,type=env,target=MYSECRET' |
  as_account blother tee "$unit_folder/podread.container" >/dev/null
as_account blother systemctl --user daemon-reload
as_account blother systemctl --user start podread.service
wait_for_journal len=15 1
[[ $(unit_state) == active ]] || fail 'podread.service must be active'
for ((attempt=0; attempt<10; attempt++)); do
  (( $(audit_reads secret/data/othersvc/pod-one) > reads_one )) && break
  sleep 1
done
(( $(audit_reads secret/data/othersvc/pod-one) > reads_one )) || fail "OpenBao's audit log must record the unit's read of othersvc/pod-one"

# While it runs, the value is in the container's files under blother's run directory and the
# container's own environment, and nowhere else.
[[ -n $(files_holding "$patterns/pod-one" "/run/user/$blother_uid") ]] || fail "a file under /run/user/$blother_uid must hold the value while the unit runs"
container_pid=$(as_account blother podman inspect --format '{{.State.Pid}}' systemd-podread)
[[ -n $(grep -lsaF -f "$patterns/pod-one" "/proc/$container_pid/environ" || true) ]] || fail "the container's environment must hold the value"
held=$(files_holding "$patterns/pod-one" /home/blother)
[[ -z $held ]] || fail "no file under blother's home may hold the value while the unit runs: $held"
[[ $(journalctl --no-pager -o verbose | count_matching "$patterns/pod-one") == 0 ]] || fail 'no journal line may hold the value'
inspected=$(as_account blother podman inspect systemd-podread)
[[ $(printf '%s' "$inspected" | count_matching "$patterns/pod-one") == 0 ]] || fail "podman inspect of the container must not hold the value"
held=$(grep -lsaF -f "$patterns/pod-one" /proc/[0-9]*/cmdline || true)
[[ -z $held ]] || fail "no process command line may hold the value: $held"
conmon_pids=$(pgrep -u "$blother_uid" -x conmon || true)
[[ -n $conmon_pids ]] || fail "conmon must run for podread.service"
for pid in $conmon_pids; do
  [[ -z $(grep -lsaF -f "$patterns/pod-one" "/proc/$pid/environ" || true) ]] || fail "conmon's environment must not hold the value"
done

# After it stops, no file anywhere the cases look holds the value.
as_account blother systemctl --user stop podread.service
held=$(files_holding "$patterns/pod-one" "/run/user/$blother_uid" /home/blother /tmp /var/tmp)
[[ -z $held ]] || fail "no file may hold the value after the unit stops: $held"
as_account blother systemctl --user start podread.service
wait_for_journal len=15 2
[[ $(unit_state) == active ]] || fail 'podread.service must be active again'

# Replacing appkey while the unit runs leaves it running, and a restart reads the new value.
podman_secret_play othersvc/pod-two
recap "$last_play_log" 1
secret_changed "$last_play_log" true
[[ $(unit_state) == active ]] || fail 'podread.service must stay active while appkey is replaced'
as_account blother systemctl --user restart podread.service
wait_for_journal len=22 1
as_account blother systemctl --user stop podread.service
[[ $(journalctl --no-pager -o verbose | count_matching "$patterns/both") == 0 ]] || fail 'no journal line may hold either value'
stop_proxy

# The ticket band's receiver pod for tbclient (OpenBao on the hub 4.3b, decisions 23, 24, 28, 36,
# 43, 72 and 76): pfnet takes the App's key from OpenBao through tbclient's Podman secret, behind
# nginx in one Quadlet pod. The key is a fresh one GitHub has never seen, so pfnet starts and
# serves /metrics, and a post that gets past nginx answers 500 from pfnet's failed GitHub call.
# The key's file and its base64 body lines, the pattern file the leak checks read, sit in the
# pattern folder under /run, outside /tmp and every home.
start_proxy 192.0.2.10
tb_uid=$(id -u tbclient)
receiver=http://127.0.0.1:18083
pod_unit=ticket-receiver-pod.service
pfnet_unit=ticket-pfnet.service
nginx_unit=ticket-nginx.service
cleanup_unit=podman-boot-cleanup.service
openssl genrsa -out "$patterns/app-key.pem" 2048 2>/dev/null
grep -v -e '-----' "$patterns/app-key.pem" >"$patterns/app-key-body"
app_key_write=$(python3 -c 'import json, sys; print(json.dumps({"data": {"value": open(sys.argv[1]).read()}}))' "$patterns/app-key.pem")
api_expect 200 'tbsvc app-key write' POST secret/data/tbsvc/app-key admin_token "$app_key_write"
unset app_key_write
tb_show() { as_account tbclient systemctl --user show "$1" -p "$2" --value; }
tb_active() { as_account tbclient systemctl --user is-active "$1" || true; }
# The HTTP status of one request; curl prints 000 when nothing answers.
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" || true; }
wait_active() {
  local unit=$1 seconds=$2 attempt
  for ((attempt=0; attempt<seconds; attempt++)); do
    [[ $(tb_active "$unit") == active ]] && return 0
    sleep 1
  done
  return 1
}
metrics_within() {
  local seconds=$1 attempt
  for ((attempt=0; attempt<seconds; attempt++)); do
    [[ $(http_code "$receiver/metrics") == 200 ]] && return 0
    sleep 1
  done
  return 1
}
receiver_up() {
  local unit
  for unit in "$pod_unit" "$pfnet_unit" "$nginx_unit"; do
    wait_active "$unit" 60 || fail "$unit must be active as tbclient; it is $(tb_active "$unit")"
  done
  metrics_within 60 || fail "GET $receiver/metrics must answer 200"
}

# The main tasks end with the morning digest, which enables and starts its timer, and the timer
# may come due while the driver runs. A drop-in holds the digest's service first: it starts only
# when the permit exists, and each start that runs removes the permit (OpenBao on the hub 4.5).
install -d -m 0755 "${digest_hold%/*}"
printf '[Unit]\nConditionPathExists=%s\n[Service]\nExecStartPre=/usr/bin/rm -f %s\n' \
  "$digest_permit" "$digest_permit" >"$digest_hold"
systemctl daemon-reload

# The pod playbook starts the pod and both containers, and pfnet answers /metrics through nginx.
play ticket-band-pod
receiver_up
printf 'receiver pod: %s, %s and %s active; GET /metrics answered 200\n' "$pod_unit" "$pfnet_unit" "$nginx_unit"
# A second run and a check run change nothing.
play ticket-band-pod
recap "$last_play_log" 0
play ticket-band-pod --check --diff
recap "$last_play_log" 0

# Only nginx's port is published, so pfnet's own port can't be reached from the runner.
[[ $(http_code http://127.0.0.1:8080/metrics) == 000 ]] || fail "pfnet's port 8080 must not answer from the runner"

# pfnet's environment holds the App's settings, and the ID template survives Ansible's templating
# and Quadlet's Environment= quoting character for character.
pfnet_env=$(as_account tbclient podman inspect --format '{{json .Config.Env}}' ticket-pfnet) ||
  fail 'podman inspect ticket-pfnet must succeed as tbclient'
PFNET_ENV=$pfnet_env python3 - <<'PY' || fail "ticket-pfnet's environment must hold the App's settings and the exact ID template"
import json, os
env = dict(entry.split('=', 1) for entry in json.loads(os.environ['PFNET_ENV']))
expected = {
    'ATG_GITHUB_APP_ID': '1',
    'ATG_GITHUB_APP_INSTALLATION_ID': '1',
    'ATG_LABELS': 'ticket',
    'ATG_AUTO_CLOSE_RESOLVED_ISSUES': 'true',
    'ATG_ALERT_ID_TEMPLATE': '{{ range $k, $v := .Payload.CommonLabels }}{{ $k }}={{ $v }};{{ end }}',
}
found = {name: env.get(name) for name in expected}
assert found == expected, found
print('ATG_ALERT_ID_TEMPLATE=' + found['ATG_ALERT_ID_TEMPLATE'])
PY
unset pfnet_env

# nginx's gate: only POST /v1/webhook with Alertmanager's password reaches pfnet, with the fixed
# owner and repository whatever query the post carries, and GET /metrics needs no password.
alert_body=$work/alert.json
cat >"$alert_body" <<'JSON'
{"receiver": "ticket", "status": "firing", "alerts": [{"status": "firing", "labels": {"alertname": "TicketBandDriver", "severity": "warning"}, "annotations": {"summary": "openbao_client driver test alert"}, "startsAt": "2026-11-10T00:00:00Z", "endsAt": "0001-01-01T00:00:00Z", "generatorURL": "http://127.0.0.1:9093/graph", "fingerprint": "5f1e4b0a3d2c1b09"}], "groupLabels": {"alertname": "TicketBandDriver"}, "commonLabels": {"alertname": "TicketBandDriver", "severity": "warning"}, "commonAnnotations": {"summary": "openbao_client driver test alert"}, "externalURL": "http://127.0.0.1:9093", "version": "4", "groupKey": "{}:{alertname=\"TicketBandDriver\"}", "truncatedAlerts": 0}
JSON
gate() {
  local expected=$1 what=$2 status
  shift 2
  status=$(http_code "$@")
  [[ $status == "$expected" ]] || fail "$what must answer $expected, got $status"
  printf '%s: %s\n' "$what" "$status"
}
post_alert() { http_code -X POST -H 'Content-Type: application/json' --data-binary "@$alert_body" "$@"; }
# pfnet's request lines come from gin's logger, which pads the method to a fixed width, so one or
# more spaces sit between POST and the quoted path. The fixed form ends at the closing quote, so a
# query appended after it doesn't match.
pfnet_lines() { as_account tbclient podman logs ticket-pfnet 2>&1 | grep -cE -e "$1" || [[ $? == 1 ]]; }
pfnet_posts() { as_account tbclient podman logs ticket-pfnet 2>&1 | grep -E -e "$any_post" | tail -"$1"; }
fixed_post='POST[[:space:]]+"/v1/webhook\?owner=sh4i-yurei&repo=platform-tickets"'
any_post='POST[[:space:]]+"/v1/webhook'
posts_before=$(pfnet_lines "$any_post")
fixed_before=$(pfnet_lines "$fixed_post")
gate 401 'POST /v1/webhook without a password' -X POST --data-binary "@$alert_body" "$receiver/v1/webhook"
gate 401 'POST /v1/webhook with a wrong password' -X POST -u alertmanager:wrong-pass --data-binary "@$alert_body" "$receiver/v1/webhook"
gate 403 'GET /v1/webhook with the password' -u alertmanager:tb-driver-pass "$receiver/v1/webhook"
gate 403 'POST /metrics' -X POST "$receiver/metrics"
gate 404 'GET /' "$receiver/"
status=$(post_alert -u alertmanager:tb-driver-pass "$receiver/v1/webhook")
[[ $status == 500 ]] || fail "POST /v1/webhook with the password and no query must answer 500 from pfnet, got $status"
printf 'POST /v1/webhook with the password and no query: %s\n' "$status"
status=$(post_alert -u alertmanager:tb-driver-pass "$receiver/v1/webhook?owner=evil&repo=x&labels=bug")
[[ $status == 500 ]] || fail "POST /v1/webhook with the password and a forged query must answer 500 from pfnet, got $status"
printf 'POST /v1/webhook with the password and a forged query: %s\n' "$status"
for ((attempt=0; attempt<20; attempt++)); do
  (( $(pfnet_lines "$any_post") - posts_before >= 2 )) && break
  sleep 1
done
(( $(pfnet_lines "$any_post") - posts_before == 2 )) || {
  as_account tbclient podman logs ticket-pfnet 2>&1 | tail -20
  fail 'pfnet must log exactly the two posts nginx let through'
}
(( $(pfnet_lines "$fixed_post") - fixed_before == 2 )) || {
  pfnet_posts 5
  fail 'pfnet must log both posts as exactly POST "/v1/webhook?owner=sh4i-yurei&repo=platform-tickets"'
}
pfnet_posts 2

# While pfnet runs, the App's key is in its environment and its runtime files under tbclient's
# run directory, and nowhere else the cases look (decision 28).
pfnet_pid=$(as_account tbclient podman inspect --format '{{.State.Pid}}' ticket-pfnet) ||
  fail 'podman inspect ticket-pfnet must succeed as tbclient'
[[ -n $(files_holding "$patterns/app-key-body" "/run/user/$tb_uid") ]] || fail "a file under /run/user/$tb_uid must hold the App's key while pfnet runs"
[[ -n $(grep -lsaF -f "$patterns/app-key-body" "/proc/$pfnet_pid/environ" || true) ]] || fail "pfnet's environment must hold the App's key"
held=$(files_holding "$patterns/app-key-body" /home/tbclient)
[[ -z $held ]] || fail "no file under tbclient's home may hold the App's key: $held"
[[ $(journalctl --no-pager -o verbose | count_matching "$patterns/app-key-body") == 0 ]] || fail "no journal line may hold the App's key"
inspected=$(as_account tbclient podman inspect ticket-pfnet)
[[ $(printf '%s' "$inspected" | count_matching "$patterns/app-key-body") == 0 ]] || fail "podman inspect ticket-pfnet must not hold the App's key"
held=$(grep -lsaF -f "$patterns/app-key-body" /proc/[0-9]*/cmdline || true)
[[ -z $held ]] || fail "no process command line may hold the App's key: $held"
conmon_pids=$(pgrep -u "$tb_uid" -x conmon || true)
[[ -n $conmon_pids ]] || fail 'conmon must run for the receiver pod'
for pid in $conmon_pids; do
  [[ -z $(grep -lsaF -f "$patterns/app-key-body" "/proc/$pid/environ" || true) ]] || fail "conmon's environment must not hold the App's key"
done
printf "App key: found under /run/user/%s and in pfnet's environment, nowhere else\n" "$tb_uid"

# With OpenBao out of reach pfnet can't read its key: its start fails and systemd tries again
# every 30 seconds, and once OpenBao answers pfnet comes up by itself (decision 24).
stop_proxy
as_account tbclient systemctl --user restart "$pfnet_unit" >/dev/null 2>&1 || true
failed_at=$(date +%s)
[[ $(tb_active "$pfnet_unit") != active ]] || fail "$pfnet_unit must fail while its secret can't be read"
[[ $(tb_show "$pfnet_unit" Result) != success ]] || fail "$pfnet_unit must record a failed start"
restarts=$(tb_show "$pfnet_unit" NRestarts)
for ((attempt=0; attempt<60; attempt++)); do
  (( $(tb_show "$pfnet_unit" NRestarts) > restarts )) && break
  sleep 1
done
waited=$(($(date +%s) - failed_at))
(( $(tb_show "$pfnet_unit" NRestarts) > restarts )) || fail "systemd must restart $pfnet_unit while its secret can't be read"
(( waited >= 25 && waited <= 40 )) || fail "systemd must restart $pfnet_unit about 30 seconds after it fails; saw $waited seconds"
printf 'pfnet without OpenBao: NRestarts %s -> %s after %ss\n' "$restarts" "$(tb_show "$pfnet_unit" NRestarts)" "$waited"
start_proxy 192.0.2.10
proxy_back=$(date +%s)
until [[ $(tb_active "$pfnet_unit") == active && $(http_code "$receiver/metrics") == 200 ]]; do
  (( $(date +%s) - proxy_back < 45 )) || fail "$pfnet_unit must be active and /metrics must answer 200 within 45 seconds of OpenBao answering"
  sleep 1
done
printf 'pfnet with OpenBao back: active and /metrics 200 after %ss\n' "$(($(date +%s) - proxy_back))"

# The pod's Wants= and After= on the boot cleanup run the cleanup again whenever the pod starts,
# and the pod starts only once it has ended (decisions 36 and 50). The microsecond timestamps
# are compared, because the cleanup usually ends within the second the pod stopped.
as_account tbclient systemctl --user stop "$pod_unit"
pod_stopped=$(tb_show "$pod_unit" InactiveEnterTimestampMonotonic)
as_account tbclient systemctl --user start "$pod_unit"
cleanup_ended=$(tb_show "$cleanup_unit" InactiveEnterTimestampMonotonic)
pod_started=$(tb_show "$pod_unit" ActiveEnterTimestampMonotonic)
(( pod_stopped > 0 && cleanup_ended > 0 && pod_started > 0 )) ||
  fail "the timestamps must all be set: pod stopped $pod_stopped, cleanup ended $cleanup_ended, pod started $pod_started"
(( cleanup_ended > pod_stopped )) || fail "the cleanup must run again between the pod's stop ($pod_stopped) and start; it last ended at $cleanup_ended"
(( cleanup_ended <= pod_started )) || fail "the cleanup must end ($cleanup_ended) no later than the pod starts ($pod_started)"
printf 'boot cleanup order: pod stopped %s, cleanup ended %s, pod started %s\n' "$pod_stopped" "$cleanup_ended" "$pod_started"
receiver_up

# A hung cleanup holds the pod back until systemd kills it at 300 seconds, and then the pod starts
# and the receiver answers (decisions 43 and 50).
hang_dropin=/home/tbclient/.config/systemd/user/$cleanup_unit.d/hang.conf
install -d -m 0755 -o tbclient -g tbclient "${hang_dropin%/*}"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' >"$hang_dropin"
chown tbclient:tbclient "$hang_dropin"
as_account tbclient systemctl --user daemon-reload
as_account tbclient systemctl --user stop "$pod_unit"
hang_start=$(date +%s)
as_account tbclient systemctl --user start --no-block "$pod_unit"
held_back=false
for ((attempt=0; attempt<175; attempt++)); do
  cleanup_state=$(tb_show "$cleanup_unit" ActiveState)
  cleanup_result=$(tb_show "$cleanup_unit" Result)
  pod_state=$(tb_show "$pod_unit" ActiveState)
  if [[ $cleanup_state == activating ]]; then
    [[ $pod_state == inactive ]] || fail "the pod must stay inactive while the cleanup is activating; it was $pod_state"
    held_back=true
  fi
  [[ $cleanup_result == timeout && $cleanup_state != activating ]] && break
  sleep 2
done
hang_elapsed=$(($(date +%s) - hang_start))
[[ $cleanup_result == timeout ]] || fail "the hung cleanup must end with Result=timeout; saw Result=$cleanup_result"
$held_back || fail 'the pod must have been seen inactive while the cleanup was activating'
((hang_elapsed >= 300 && hang_elapsed < 330)) || fail "the hung cleanup must time out 300 to 329 seconds after the start; saw $hang_elapsed"
wait_active "$pod_unit" 30 || fail "the pod must start once the hung cleanup is killed; it is $(tb_active "$pod_unit")"
pod_active_at=$(date +%s)
cleanup_ended=$(tb_show "$cleanup_unit" InactiveEnterTimestampMonotonic)
pod_started=$(tb_show "$pod_unit" ActiveEnterTimestampMonotonic)
(( cleanup_ended > 0 && pod_started >= cleanup_ended )) || fail "the pod must start ($pod_started) after the cleanup is killed ($cleanup_ended)"
metrics_within 60 || fail "GET $receiver/metrics must answer 200 within 60 seconds of the pod starting"
printf 'hung cleanup: Result=%s after %ss; the pod started after it, /metrics 200 after %ss more\n' \
  "$cleanup_result" "$hang_elapsed" "$(($(date +%s) - pod_active_at))"
rm -f -- "$hang_dropin"
as_account tbclient systemctl --user daemon-reload
as_account tbclient systemctl --user reset-failed "$cleanup_unit"
receiver_up

# The role's verify asks only what holds while OpenBao is down: the pod is active and nginx
# refuses a post without the password (decision 76). pfnet is restarted with the proxy stopped, so
# it can't read its key and is down while verify runs. Without nginx verify fails with its message.
stop_proxy
as_account tbclient systemctl --user restart "$pfnet_unit" >/dev/null 2>&1 || true
[[ $(tb_active "$pfnet_unit") != active ]] || fail "$pfnet_unit must be down while its secret can't be read"
play ticket-band-verify-pod
as_account tbclient systemctl --user stop "$nginx_unit"
play_fails verify-pod-without-nginx ticket-band-verify-pod 'The receiver pod must be active and nginx must refuse a post without the password'
start_proxy 192.0.2.10
as_account tbclient systemctl --user start "$nginx_unit"
receiver_up

# The morning digest end to end for tbclient (OpenBao on the hub 4.5, decisions 10, 26, 28, 78 and
# 82): openbao-read takes the App's key from the real OpenBao through the proxy stand-in, and
# digest_standin.py stands in for GitHub and ntfy. The public key, which the stand-in verifies the
# App token with, sits beside the key in the pattern folder.
openssl rsa -in "$patterns/app-key.pem" -pubout -out "$patterns/app-key.pub" 2>/dev/null
standin_log=$work/digest-standin.jsonl
: >"$standin_log"
python3 tests/openbao_client/digest_standin.py "$patterns/app-key.pub" "$standin_log" >"$work/digest-standin.log" 2>&1 &
standin_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  if listening 18400 && listening 18401; then break; fi
  sleep 0.2
done
listening 18400 && listening 18401 || { cat "$work/digest-standin.log" >&2; fail 'the digest stand-in must listen on 18400 and 18401'; }
# The probes above are requests too; the log starts empty from here.
: >"$standin_log"
play ticket-band-digest
held_status=0
systemctl start ticket-digest.service || held_status=$?
held_condition=$(systemctl show ticket-digest.service -p ConditionResult --value)
held_requests=$(wc -l <"$standin_log")
[[ $held_status == 0 && $held_condition == no && $held_requests == 0 ]] ||
  fail "a start of ticket-digest.service without the driver's permit must be skipped and reach no stand-in; saw exit $held_status, ConditionResult=$held_condition, $held_requests stand-in requests"
printf 'held digest: exit 0, ConditionResult=no, no stand-in request\n'
touch "$digest_permit"
digest_start=$(date +%s)
systemctl start ticket-digest.service || fail "the digest for tbclient must succeed; $(systemctl show ticket-digest.service -p Result)"
digest_result=$(systemctl show ticket-digest.service -p Result --value)
[[ $digest_result == success ]] || fail "the digest for tbclient must end with Result=success; saw $digest_result"
printf 'digest for tbclient: Result=%s in %ss\n' "$digest_result" "$(($(date +%s) - digest_start))"
python3 - "$standin_log" <<'PY' || { cat "$standin_log" >&2; fail "the stand-ins must see one verified token request, both lists, the revoke and one ntfy post"; }
import json, pathlib, sys
entries = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
print('stand-in saw:', [(e['server'], e['method'], e['path']) for e in entries])
tokens = [e for e in entries if e['server'] == 'github' and e['method'] == 'POST']
assert [(e['path'], e['verified'], e['claims']['iss']) for e in tokens] == [('/app/installations/1/access_tokens', True, '1')], tokens
lists = [e for e in entries if e['server'] == 'github' and e['method'] == 'GET']
assert [(e['path'], e['query']['state'], e['installation_token']) for e in lists] == [
    ('/repos/sh4i-yurei/platform-tickets/issues', ['open'], True),
    ('/repos/sh4i-yurei/platform-tickets/issues', ['closed'], True),
], lists
revokes = [e for e in entries if e['server'] == 'github' and e['method'] == 'DELETE']
assert [(e['path'], e['installation_token']) for e in revokes] == [('/installation/token', True)], revokes
posts = [e for e in entries if e['server'] == 'ntfy']
assert [(e['method'], e['path'], e['authorization'], e['title']) for e in posts] == [
    ('POST', '/tickets', 'Bearer tb-digest-token-not-real', 'Tickets: 1 open, 0 closed in the last day'),
], posts
assert posts[0]['body'] == '#1 A stand-in ticket https://github.com/sh4i-yurei/platform-tickets/issues/1', posts
PY
# The run unit's own output and its manager's lines about it, both under tbclient's uid.
journalctl --no-pager -o cat "_UID=$tb_uid" _SYSTEMD_USER_UNIT=ticket-digest-run.service + \
  "_UID=$tb_uid" USER_UNIT=ticket-digest-run.service >"$work/digest-journal.log"
digest_journal_lines=$(wc -l <"$work/digest-journal.log")
((digest_journal_lines >= 1)) || fail 'the journal query for the digest run unit must find at least one line'
if grep -Fq tb-digest-token-not-real "$work/digest-journal.log"; then fail "the digest's journal must not hold the ntfy token"; fi
[[ $(count_matching "$patterns/app-key-body" <"$work/digest-journal.log") == 0 ]] || fail "the digest's journal must not hold the App's key"
held=$(files_holding "$patterns/app-key-body" /home/tbclient /etc /tmp /var/tmp)
[[ -z $held ]] || fail "no file under /home/tbclient, /etc, /tmp or /var/tmp may hold the App's key after the digest: $held"
printf 'digest journal: %s lines, neither the ntfy token nor the App key\n' "$digest_journal_lines"
stop_digest_standin
stop_proxy

no_leftover_tokens
api_expect 204 'keepbreath0 token revoke' POST auth/token/revoke-self admin_token
logs_clean
printf 'openbao_client driver: all cases passed\n'
