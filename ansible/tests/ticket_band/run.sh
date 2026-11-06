#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=tbtest
home=/home/$user
unit=podman-boot-cleanup.service
config=$home/.config/containers/storage.conf
dropin=$home/.config/systemd/user/$unit.d/hang.conf
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'tbtest already exists'; fi

work=$(mktemp -d)
undo_add 'remove ticket band driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_install
runner_save_environment
undo_add 'remove driver-created tbtest' undo_account
undo_account() {
  if id -u "$user" >/dev/null 2>&1; then
    rm -f -- "$dropin"
    runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1 || {
      cat "$work/account-cleanup.log" >&2
      return 1
    }
  fi
}

play() {
  local label=$1
  shift
  if ! ansible-playbook -i localhost, "tests/ticket_band/$label.yml" "$@" >"$work/$label.log" 2>&1; then
    tail -45 "$work/$label.log"
    fail "$label play must pass"
  fi
}
recap() {
  grep -Eq "localhost[[:space:]]+:.*changed=$2 .*failed=0" "$1" || {
    tail -35 "$1"
    fail "$1 recap must have changed=$2 and failed=0"
  }
}
changed_task() {
  python3 - "$1" "$2" <<'PY' || fail "$2 must report changed"
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r'TASK \[ticket_band : ' + re.escape(sys.argv[2]) + r'\][^\n]*\nchanged: \[localhost\]', log)
PY
}
as_user() {
  (
    cd "$home"
    HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
      XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
  )
}
verify_fails() {
  if ansible-playbook -i localhost, tests/ticket_band/verify.yml >"$work/verify-fail.log" 2>&1; then
    fail 'verify unexpectedly passed without transient store'
  fi
  grep -Fq '"msg": "The band'"'"'s account must run Podman with the transient store"' "$work/verify-fail.log" || {
    tail -25 "$work/verify-fail.log"
    fail 'verify did not report the missing transient store'
  }
}

if ansible-playbook -i localhost, tests/ticket_band/missing-user.yml >"$work/missing.log" 2>&1; then
  fail 'missing ticket_band_user was accepted'
fi
grep -Fq 'missing required arguments: ticket_band_user' "$work/missing.log" || {
  tail -30 "$work/missing.log"
  fail 'missing user did not fail argument validation'
}
if id -u "$user" >/dev/null 2>&1; then fail 'missing-user play created tbtest'; fi

play role --check --diff
changed_task "$work/role.log" 'Ticket band | Create the account'
changed_task "$work/role.log" 'Ticket band | Write transient storage configuration'
changed_task "$work/role.log" 'Ticket band | Write boot cleanup unit'
if id -u "$user" >/dev/null 2>&1; then fail 'check mode created tbtest'; fi

play role
python3 - "$config" "$user" <<'PY' || fail 'storage configuration must match and belong to tbtest'
import configparser, os, pathlib, pwd, sys
path = pathlib.Path(sys.argv[1])
config = configparser.ConfigParser()
config.read(path)
assert dict(config['storage']) == {'driver': '"overlay"', 'transient_store': 'true'}
assert path.stat().st_uid == pwd.getpwnam(sys.argv[2]).pw_uid
PY
test -e "/var/lib/systemd/linger/$user" || fail 'linger must be enabled'
as_user podman info --format json >"$work/podman.json"
python3 - "$work/podman.json" "$(id -u "$user")" <<'PY' || fail 'Podman must use transient overlay storage under the runtime directory'
import json, sys
store = json.load(open(sys.argv[1]))['store']
assert store['transientStore'] is True
assert store['graphDriverName'] == 'overlay'
assert store['runRoot'].startswith('/run/user/' + sys.argv[2] + '/')
PY
test "$(as_user systemctl --user is-enabled "$unit")" = enabled || fail 'cleanup unit must be enabled'
as_user systemctl --user show "$unit" -p Type -p TimeoutStartUSec >"$work/unit-show"
grep -Fxq 'Type=oneshot' "$work/unit-show" || fail 'cleanup must be oneshot'
grep -Fxq 'TimeoutStartUSec=5min' "$work/unit-show" || fail 'cleanup timeout must be five minutes'
as_user systemctl --user start "$unit"
test "$(as_user systemctl --user show "$unit" -p Result --value)" = success || fail 'cleanup must succeed'
test "$(as_user systemctl --user show "$unit" -p ExecMainStatus --value)" = 0 || fail 'cleanup exit status must be zero'

install -d -m 0755 -o "$user" -g "$user" "${dropin%/*}"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' >"$dropin"
chown "$user:$user" "$dropin"
as_user systemctl --user daemon-reload
start=$(date +%s)
as_user systemctl --user start --no-block "$unit"
for ((attempt=0; attempt<165; attempt++)); do
  result=$(as_user systemctl --user show "$unit" -p Result --value)
  state=$(as_user systemctl --user show "$unit" -p ActiveState --value)
  if [[ $result == timeout && $state == failed ]]; then break; fi
  sleep 2
done
elapsed=$(($(date +%s) - start))
[[ $result == timeout && $state == failed ]] || fail 'hung cleanup must fail with Result=timeout'
((elapsed >= 300 && elapsed < 330)) || fail "hung cleanup must time out in 300 to 329 seconds; saw $elapsed"
printf 'hung cleanup: Result=%s ActiveState=%s elapsed=%ss\n' "$result" "$state" "$elapsed"
rm -f -- "$dropin"
as_user systemctl --user daemon-reload
as_user systemctl --user reset-failed "$unit"
as_user systemctl --user start "$unit"
test "$(as_user systemctl --user show "$unit" -p Result --value)" = success || fail 'cleanup must recover after timeout'

sed -i '/^transient_store = true$/d' "$config"
verify_fails
play role
play verify
play role
recap "$work/role.log" 0
play role --check --diff
recap "$work/role.log" 0

printf 'ticket_band driver: all cases passed\n'
