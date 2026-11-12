#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=bltest
home=/home/$user
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'bltest already exists'; fi

work=$(mktemp -d)
undo_add 'remove baseline container account driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_install
runner_save_environment
undo_add 'remove driver-created bltest' undo_account
undo_account() {
  if id -u "$user" >/dev/null 2>&1; then
    if ! runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1; then
      cat "$work/account-cleanup.log" >&2
      return 1
    fi
    if grep -vFx 'userdel: bltest mail spool (/var/mail/bltest) not found' "$work/account-cleanup.log" >"$work/unexpected-cleanup.log"; then
      cat "$work/unexpected-cleanup.log" >&2
      return 1
    fi
  fi
}

play_index=0
play() {
  local label=$1 account=$2 log
  shift 2
  play_index=$((play_index + 1))
  log="$work/$label-$play_index.log"
  last_play_log=$log
  if ! ansible-playbook -i localhost, tests/baseline_container_account/role.yml -e "account=$account" "$@" >"$log" 2>&1; then
    tail -45 "$log"
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
  python3 - "$1" "$2" <<'PY' || fail "$2 must report changed on localhost"
import pathlib, re, sys
log, title = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
assert re.search(r'TASK \[baseline : ' + re.escape(title) + r'\][^\n]*\nchanged: \[localhost\]', log)
PY
}
as_user() {
  (
    cd "$home"
    HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
      XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
  )
}
manager_active() { systemctl is-active --quiet "user@$(id -u "$user").service"; }

play empty ''
recap "$last_play_log" 0
printf 'PASS empty account: changed=0\n'

useradd -m "$user"
play fresh-check "$user" --check --diff
recap "$last_play_log" 2
changed_task "$last_play_log" 'container-account | Start the container account'"'"'s user manager'
test ! -e "/var/lib/systemd/linger/$user" || fail 'fresh check enabled lingering'
if manager_active; then fail 'fresh check started the user manager'; fi
printf 'PASS fresh account check: changed=2, reports the start, creates nothing\n'

play fresh-run "$user"
test -e "/var/lib/systemd/linger/$user" || fail 'real run did not enable lingering'
as_user systemctl --user show-environment >"$work/fresh-user-manager.log" 2>&1 || {
  cat "$work/fresh-user-manager.log"
  fail 'fresh account user manager does not answer'
}
printf 'PASS fresh account run: lingering and user manager work\n'

play repeat-run "$user"
recap "$last_play_log" 0
printf 'PASS second run: changed=0\n'

systemctl stop "user@$(id -u "$user").service"
if manager_active; then fail 'manager remained active after stop'; fi
play stopped-check "$user" --check --diff
recap "$last_play_log" 1
changed_task "$last_play_log" 'container-account | Start the container account'"'"'s user manager'
if manager_active; then fail 'stopped-manager check started the manager'; fi
printf 'PASS stopped manager check: changed=1, reports start, leaves manager stopped\n'

play stopped-run "$user"
changed_task "$last_play_log" 'container-account | Start the container account'"'"'s user manager'
as_user systemctl --user show-environment >"$work/restarted-user-manager.log" 2>&1 || {
  cat "$work/restarted-user-manager.log"
  fail 'stopped manager did not restart'
}
printf 'PASS stopped manager run: reports start and manager answers\n'

play after-restart "$user"
recap "$last_play_log" 0
play after-restart-check "$user" --check --diff
recap "$last_play_log" 0
printf 'PASS after restart: real and check runs changed=0\n'

printf 'baseline_container_account driver: all cases passed\n'
