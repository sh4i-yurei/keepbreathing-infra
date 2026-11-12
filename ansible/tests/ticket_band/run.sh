#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=tbtest
home=/home/$user
unit=podman-boot-cleanup.service
config=$home/.config/containers/storage.conf
dropin=$home/.config/systemd/user/$unit.d/hang.conf
# The morning digest's files, its drop-in holding the service, the drop-in's permit and the timer's
# stamp (OpenBao on the hub 4.5).
digest_hold=/run/systemd/system/ticket-digest.service.d/driver-hold.conf
digest_permit=/run/ticket-digest-driver-permit
digest_paths=(/usr/local/libexec/ticket-digest /etc/ticket-digest.json
  /etc/systemd/system/ticket-digest.service /etc/systemd/system/ticket-digest.timer
  "$digest_hold" "$digest_permit" /var/lib/systemd/timers/stamp-ticket-digest.timer)
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'tbtest already exists'; fi
for path in "${digest_paths[@]}"; do
  if [[ -e $path || -L $path ]]; then fail "$path already exists"; fi
done

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
# Registered after the account's undo, so it runs first: the timer is gone before tbtest is. The
# disable is quiet, because the job requires the driver's success line to be its last.
undo_add 'remove the morning digest' undo_digest
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
# changed_task <log> <task> [role]: the role defaults to ticket_band, whose account part also
# includes openbao_client's podman-account.
changed_task() {
  python3 - "$1" "$2" "${3:-ticket_band}" <<'PY' || fail "$2 must report changed"
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r'TASK \[' + re.escape(sys.argv[3]) + r' : ' + re.escape(sys.argv[2]) + r'\][^\n]*\nchanged: \[localhost\]', log)
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
changed_task "$work/role.log" 'OpenBao client | Predict the default Podman secret driver' openbao_client
if id -u "$user" >/dev/null 2>&1; then fail 'check mode created tbtest'; fi

# The account part and then the main tasks, in check mode for an account that doesn't exist yet,
# report the account's files and the receiver pod's three Quadlet files, and make nothing.
play check-mode --check --diff
changed_task "$work/check-mode.log" 'Ticket band | Create the account'
changed_task "$work/check-mode.log" 'Ticket band | Write transient storage configuration'
changed_task "$work/check-mode.log" 'Ticket band | Write boot cleanup unit'
changed_task "$work/check-mode.log" 'OpenBao client | Predict the default Podman secret driver' openbao_client
python3 - "$work/check-mode.log" <<'PY' || { tail -45 "$work/check-mode.log"; fail 'check mode must report the three Quadlet files as changed'; }
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
header = "TASK [ticket_band : Ticket band | Write the receiver pod's Quadlet files]"
assert header in log, 'the log names no Quadlet file task'
section = log.split(header, 1)[1].split('\nTASK [', 1)[0]
for name in ('ticket-receiver.pod', 'ticket-pfnet.container', 'ticket-nginx.container'):
    assert re.search(r'^changed: \[localhost\] => \(item=' + re.escape(name) + r'\)', section, re.MULTILINE), (name, section)
PY
if id -u "$user" >/dev/null 2>&1; then fail 'check mode of the main tasks created tbtest'; fi
# The main tasks end with the morning digest, which predicts the account's token file.
python3 - "$work/check-mode.log" "$home" <<'PY' || { tail -45 "$work/check-mode.log"; fail "check mode must predict the digest's ntfy token"; }
import pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
header = "TASK [ticket_band : Ticket band | Write the digest's ntfy token]"
assert header in log, 'the log names no token task'
section = log.split(header, 1)[1].split('\nTASK [', 1)[0]
assert any(line.startswith('changed: [localhost]') for line in section.splitlines()), section
assert '"msg": "Would write ' + sys.argv[2] + '/.config/ticket-digest/ntfy-token"' in section, section
PY
if grep -Fq tb-digest-token-not-real "$work/check-mode.log"; then fail 'the check-mode log must not hold the stand-in token'; fi

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
# The account part makes openbao-podman-secret tbtest's default Podman secret driver, as tbtest,
# only after it has written the transient storage (OpenBao on the hub decisions 72 and 75).
dropin_folder=$home/.config/containers/containers.conf.d
[[ $(stat -c '%U %a %F' "$dropin_folder") == "$user 700 directory" ]] || fail "$dropin_folder must be tbtest's with mode 0700"
[[ $(stat -c '%U %a %F' "$dropin_folder/openbao.conf") == "$user 600 regular file" ]] || fail "openbao.conf must be tbtest's regular file with mode 0600"
cmp -s - "$dropin_folder/openbao.conf" <<'EOF' || fail 'openbao.conf must hold exactly the shell driver and its four commands'
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
python3 - "$work/role.log" <<'PY' || fail 'transient storage must be written before the secret driver drop-in'
import pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
storage = log.index('TASK [ticket_band : Ticket band | Write transient storage configuration]')
dropin = log.index('TASK [openbao_client : OpenBao client | Write the OpenBao secret driver drop-in]')
assert storage < dropin, (storage, dropin)
PY
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
# A stopped user manager with lingering still on: the role must start it itself (#139).
systemctl stop "user@$(id -u "$user").service"
play role
changed_task "$work/role.log" "Ticket band | Start the account's user manager"
test "$(as_user systemctl --user is-enabled podman-boot-cleanup.service)" = enabled || fail 'boot cleanup must stay enabled after the user manager restarts'
play role
recap "$work/role.log" 0
play role --check --diff
recap "$work/role.log" 0

# The morning digest (OpenBao on the hub 4.5, decisions 26, 29, 35 and 78), through tasks_from:
# digest. The role enables and starts its timer, and the timer may come due while the driver runs,
# so a drop-in holds the service first: it starts only when the permit exists, and each start that
# runs removes the permit. The driver's own starts touch the permit first.
run_unit=ticket-digest-run.service
run_dropin=$home/.config/systemd/user/$run_unit.d/driver.conf
install -d -m 0755 "${digest_hold%/*}"
printf '[Unit]\nConditionPathExists=%s\n[Service]\nExecStartPre=/usr/bin/rm -f %s\n' \
  "$digest_permit" "$digest_permit" >"$digest_hold"
systemctl daemon-reload
play digest
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/digest.log" || fail 'the first digest run must not fail'
grep -E -o 'localhost[[:space:]]+:.*' "$work/digest.log"

# A start without the permit, as the timer's own start at 07:00 would be, is skipped.
held_status=0
systemctl start ticket-digest.service || held_status=$?
held_condition=$(systemctl show ticket-digest.service -p ConditionResult --value)
held_invocation=$(as_user systemctl --user show "$run_unit" -p InvocationID --value)
[[ $held_status == 0 && $held_condition == no && -z $held_invocation ]] ||
  fail "a start of ticket-digest.service without the driver's permit must be skipped; saw exit $held_status, ConditionResult=$held_condition, run unit InvocationID=$held_invocation"
printf 'held digest: exit 0, ConditionResult=no, run unit never started\n'

[[ $(stat -c '%U:%G %a %F' /usr/local/libexec/ticket-digest) == 'root:root 755 regular file' ]] || fail '/usr/local/libexec/ticket-digest must be root:root 0755'
cmp -s roles/ticket_band/files/ticket-digest.py /usr/local/libexec/ticket-digest || fail '/usr/local/libexec/ticket-digest must be the role file'
[[ $(stat -c '%U:%G %a %F' /etc/ticket-digest.json) == 'root:root 644 regular file' ]] || fail '/etc/ticket-digest.json must be root:root 0644'
python3 - "$home" <<'PY' || fail '/etc/ticket-digest.json must hold exactly the digest settings and no secret'
import json, pathlib, sys
text = pathlib.Path('/etc/ticket-digest.json').read_text()
assert 'tb-digest-token-not-real' not in text and 'PRIVATE KEY' not in text
assert json.loads(text) == {
    'app_id': 1, 'installation_id': 1, 'owner': 'sh4i-yurei', 'repository': 'platform-tickets',
    'label': 'ticket', 'key_path': 'tbsvc/app-key', 'reader': '/usr/local/bin/openbao-read',
    'github_api': 'https://api.github.com', 'ntfy_url': 'http://127.0.0.1:8080/tickets',
    'ntfy_token_file': sys.argv[1] + '/.config/ticket-digest/ntfy-token',
}, text
PY
[[ $(stat -c '%U:%G %a %F' "$home/.config/ticket-digest") == "$user:$user 700 directory" ]] || fail "$home/.config/ticket-digest must be tbtest's with mode 0700"
[[ $(stat -c '%U:%G %a %F' "$home/.config/ticket-digest/ntfy-token") == "$user:$user 600 regular file" ]] || fail 'ntfy-token must be tbtest:tbtest with mode 0600'
printf 'tb-digest-token-not-real\n' | cmp -s - "$home/.config/ticket-digest/ntfy-token" || fail 'ntfy-token must hold exactly the stand-in token and a newline'
if grep -Fq tb-digest-token-not-real "$work/digest.log"; then fail 'the digest log must not hold the stand-in token'; fi
as_user systemctl --user show "$run_unit" -p Type -p TimeoutStartUSec >"$work/run-unit-show"
grep -Fxq 'Type=oneshot' "$work/run-unit-show" || fail "$run_unit must be oneshot"
grep -Fxq 'TimeoutStartUSec=5min' "$work/run-unit-show" || fail "$run_unit must time out after 5 minutes"
[[ $(systemctl show ticket-digest.service -p TimeoutStartUSec --value) == 10min ]] || fail 'ticket-digest.service must time out after 10 minutes'
[[ $(systemctl is-enabled ticket-digest.timer) == enabled ]] || fail 'ticket-digest.timer must be enabled'
[[ $(systemctl is-active ticket-digest.timer) == active ]] || fail 'ticket-digest.timer must be active'
timer_calendar=$(systemctl show ticket-digest.timer -p TimersCalendar)
[[ $timer_calendar == *'OnCalendar=*-*-* 07:00:00 ;'* ]] || fail "ticket-digest.timer must fire at 07:00; saw $timer_calendar"
timer_persistent=$(systemctl show ticket-digest.timer -p Persistent)
[[ $timer_persistent == Persistent=yes ]] || fail "ticket-digest.timer must be persistent; saw $timer_persistent"
printf '%s %s\n' "$timer_calendar" "$timer_persistent"
as_user /usr/bin/python3 -c 'import jwt, cryptography' || fail '/usr/bin/python3 must import jwt and cryptography as tbtest'

# A run unit that exits 3 fails it, and with it the system service that waits for it (decision 29).
install -d -m 0755 -o "$user" -g "$user" "${run_dropin%/*}"
printf '[Service]\nExecStart=\nExecStart=/bin/sh -c "exit 3"\n' >"$run_dropin"
chown "$user:$user" "$run_dropin"
as_user systemctl --user daemon-reload
touch "$digest_permit"
if systemctl start ticket-digest.service; then fail 'a failing digest must fail ticket-digest.service'; fi
[[ ! -e $digest_permit ]] || fail 'a start that runs must remove the permit'
run_result=$(as_user systemctl --user show "$run_unit" -p Result --value)
run_status=$(as_user systemctl --user show "$run_unit" -p ExecMainStatus --value)
service_state=$(systemctl show ticket-digest.service -p ActiveState --value)
service_result=$(systemctl show ticket-digest.service -p Result --value)
[[ $run_result == exit-code && $run_status == 3 && $service_state == failed && $service_result == exit-code ]] ||
  fail "a failing digest must leave the run unit exit-code/3 and the service failed/exit-code; saw $run_result/$run_status and $service_state/$service_result"
printf 'failing digest: run unit %s/%s, system service %s/%s\n' "$run_result" "$run_status" "$service_state" "$service_result"
as_user systemctl --user reset-failed "$run_unit"
systemctl reset-failed ticket-digest.service

# A run unit that hangs past its time limit fails the same way, within the limit (decision 29).
printf '[Service]\nExecStart=\nExecStart=/usr/bin/sleep infinity\n' >"$run_dropin"
chown "$user:$user" "$run_dropin"
play digest -e ticket_band_digest_timeout=20
as_user systemctl --user daemon-reload
touch "$digest_permit"
hang_start=$(date +%s)
if systemctl start ticket-digest.service; then fail 'a hanging digest must fail ticket-digest.service'; fi
hang_elapsed=$(($(date +%s) - hang_start))
run_result=$(as_user systemctl --user show "$run_unit" -p Result --value)
service_state=$(systemctl show ticket-digest.service -p ActiveState --value)
service_result=$(systemctl show ticket-digest.service -p Result --value)
[[ $run_result == timeout && $service_state == failed && $service_result == exit-code ]] ||
  fail "a hanging digest must leave the run unit timeout and the service failed/exit-code; saw $run_result and $service_state/$service_result"
((hang_elapsed >= 20 && hang_elapsed < 40)) || fail "a hanging digest must fail in 20 to 39 seconds; saw $hang_elapsed"
printf 'hanging digest: run unit %s, system service %s/%s, elapsed=%ss\n' "$run_result" "$service_state" "$service_result" "$hang_elapsed"
rm -f -- "$run_dropin"
rmdir -- "${run_dropin%/*}"
as_user systemctl --user daemon-reload
as_user systemctl --user reset-failed "$run_unit"
systemctl reset-failed ticket-digest.service

# The default time limits come back, and a second run and a check run change nothing.
play digest
[[ $(as_user systemctl --user show "$run_unit" -p TimeoutStartUSec --value) == 5min ]] || fail "$run_unit must time out after 5 minutes again"
[[ $(systemctl show ticket-digest.service -p TimeoutStartUSec --value) == 10min ]] || fail 'ticket-digest.service must time out after 10 minutes again'
play digest
recap "$work/digest.log" 0
play digest --check --diff
recap "$work/digest.log" 0
python3 - "$work/digest.log" <<'PY' || { tail -45 "$work/digest.log"; fail "the check run must report the digest's ntfy token ok"; }
import pathlib, sys
log = pathlib.Path(sys.argv[1]).read_text()
# The prediction for a fresh account shares the task's name and is skipped here.
sections = [part.split('\nTASK [', 1)[0] for part in log.split("TASK [ticket_band : Ticket band | Write the digest's ntfy token]")[1:]]
statuses = [line.split(':', 1)[0] for section in sections for line in section.splitlines() if line.startswith(('ok:', 'changed:', 'skipping:'))]
assert sorted(statuses) == ['ok', 'skipping'], statuses
PY
if grep -Fq tb-digest-token-not-real "$work/digest.log"; then fail 'the check run log must not hold the stand-in token'; fi
[[ $(systemctl is-enabled ticket-digest.timer) == enabled && $(systemctl is-active ticket-digest.timer) == active ]] ||
  fail 'ticket-digest.timer must stay enabled and active'

# A link tbtest plants at .config/containers, to a root-owned folder, fails the run, because the
# account part works in the home as tbtest; the folder keeps root's owner and mode and gets no
# file (OpenBao on the hub decision 61).
planted=/srv/ticket-band-planted
[[ ! -e $planted && ! -L $planted ]] || fail "$planted already exists"
undo_add "remove $planted" undo_planted
undo_planted() { rm -rf -- "$planted"; }
install -d -m 0755 -o root -g root "$planted"
rm -rf -- "$home/.config/containers"
ln -s "$planted" "$home/.config/containers"
chown -h "$user:$user" "$home/.config/containers"
if ansible-playbook -i localhost, tests/ticket_band/role.yml >"$work/planted.log" 2>&1; then
  fail 'role run through a planted .config/containers link unexpectedly passed'
fi
python3 - "$work/planted.log" <<'PY' || { tail -45 "$work/planted.log"; fail 'the planted link must fail Create private configuration directories with chown failed'; }
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
header = 'TASK [ticket_band : Ticket band | Create private configuration directories]'
after = log.split(header, 1)[1].split('\nPLAY RECAP', 1)[0]
assert '"msg": "chown failed"' in after, after
assert re.search(r'^failed: \[localhost\] \(item=\.config/containers\)', after, re.MULTILINE), after
assert 'TASK [' not in after, 'the play went past the failed task'
assert re.search(r'localhost\s+:.*failed=1 ', log), 'the recap must count one failure'
PY
grep -F -m1 -o '"msg": "chown failed"' "$work/planted.log"
[[ $(stat -c '%U %a' "$planted") == 'root 755' ]] || fail "$planted must stay root's with mode 0755; saw $(stat -c '%U %a' "$planted")"
[[ -z $(find "$planted" -mindepth 1 -print -quit) ]] || fail "$planted must hold no file"
printf 'planted link: %s stays %s and empty\n' "$planted" "$(stat -c '%U %a' "$planted")"
rm -f -- "$home/.config/containers"
rm -rf -- "$planted"

printf 'ticket_band driver: all cases passed\n'
