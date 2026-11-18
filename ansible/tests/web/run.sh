#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=webtest
site=/srv/keepbreathing
api=/srv/keepbreath-contact-api
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'webtest already exists'; fi
if test -e "$site" || test -L "$site"; then fail '/srv/keepbreathing already exists'; fi
if test -e "$api" || test -L "$api"; then fail '/srv/keepbreath-contact-api already exists'; fi

work=$(mktemp -d)
created_account=false
created_site=false
created_api=false
undo_add 'remove web driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_add 'remove driver-created web account' undo_account
undo_account() {
  if $created_account && id -u "$user" >/dev/null 2>&1; then
    if ! runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1; then
      cat "$work/account-cleanup.log" >&2
      return 1
    fi
    if grep -vFx 'userdel: webtest mail spool (/var/mail/webtest) not found' "$work/account-cleanup.log" >"$work/unexpected-cleanup.log"; then
      cat "$work/unexpected-cleanup.log" >&2
      return 1
    fi
  fi
}
undo_add 'remove driver-created site checkout' undo_site
undo_site() { if $created_site; then rm -rf -- "$site"; fi; }
undo_add 'remove driver-created contact API checkout' undo_api
undo_api() { if $created_api; then rm -rf -- "$api"; fi; }
undo_install

play() {
  local label=$1 site_ref=$2 api_ref=$3
  shift 3
  last_log="$work/$label.log"
  ansible-playbook -i localhost, tests/web/role.yml \
    -e "web_container_user=$user" -e "web_site_ref=$site_ref" \
    -e "web_contact_api_ref=$api_ref" "$@" >"$last_log" 2>&1
}
recap() {
  grep -Eq "localhost[[:space:]]+:.*changed=$2 .*failed=0" "$1" || {
    tail -45 "$1"
    fail "$1 recap must have changed=$2 and failed=0"
  }
}
head_at() {
  runuser -u "$user" -- git -C "$1" rev-parse --short=7 HEAD
}
expect_head() {
  local actual
  actual=$(head_at "$1")
  test "$actual" = "$2" || fail "$1 HEAD was $actual, expected $2"
}

if ansible localhost -i localhost, -c local --playbook-dir tests/web \
  -m ansible.builtin.include_role -a name=web \
  -e 'web_container_user=webabsent' -e 'web_site_ref=949b89f' \
  -e 'web_contact_api_ref=0c856b9' >"$work/missing-account.log" 2>&1; then
  fail 'missing account was accepted'
fi
grep -F 'web: the account webabsent does not exist; run the web role'"'"'s account entry point before baseline' "$work/missing-account.log" >/dev/null || fail 'missing account message differs'
if id -u webabsent >/dev/null 2>&1; then fail 'missing account was created'; fi
test ! -e "$site" && test ! -e "$api" || fail 'missing account made a checkout'
printf 'PASS missing account: role fails before making a checkout\n'

created_account=true
created_site=true
created_api=true
if ! play fresh-check 949b89f 0c856b9 --check --diff; then tail -45 "$last_log"; fail 'fresh check failed'; fi
recap "$last_log" 1
if id -u "$user" >/dev/null 2>&1; then fail 'fresh check created account'; fi
test ! -e "$site" && test ! -e "$api" || fail 'fresh check created a checkout'
printf 'PASS fresh check: changed=1, nothing created\n'

if ! play first 949b89f 0c856b9; then tail -45 "$last_log"; fail 'first run failed'; fi
test "$(grep -c "^$user:" /etc/subuid)" = 1 || fail 'subuid entries differ'
test "$(grep -c "^$user:" /etc/subgid)" = 1 || fail 'subgid entries differ'
for path in "$site" "$api"; do
  test "$(stat -c '%a %U:%G' "$path")" = '755 webtest:webtest' || fail "$path ownership or mode differs"
done
expect_head "$site" 949b89f
expect_head "$api" 0c856b9
printf 'PASS first run: account, subordinate IDs, paths and refs\n'

if ! play second 949b89f 0c856b9; then tail -45 "$last_log"; fail 'second run failed'; fi
recap "$last_log" 0
printf 'PASS second run: changed=0\n'

if ! play repeat-check 949b89f 0c856b9 --check --diff; then tail -45 "$last_log"; fail 'repeat check failed'; fi
recap "$last_log" 0
printf 'PASS check mode after a run: changed=0\n'

if ! play different-refs 63ae43b 2bf47f7; then tail -45 "$last_log"; fail 'different refs failed'; fi
recap "$last_log" 0
expect_head "$site" 949b89f
expect_head "$api" 0c856b9
printf 'PASS existing checkouts: both HEADs stay put\n'

rm -rf -- "$site"
if play old-site 63ae43b 0c856b9; then fail 'old site was accepted'; fi
grep -F 'web: the site checkout /srv/keepbreathing does not publish 127.0.0.1:8080 (no line PublishPort=127.0.0.1:8080:8080 in deploy/quadlet/keepbreath.container); deploy keepbreathing #39, the loopback server, first (Ansible configuration management decision 61.9)' "$last_log" >/dev/null || fail 'old site failure differs'
expect_head "$api" 0c856b9
printf 'PASS old site: loopback guard rejects 63ae43b\n'

rm -rf -- "$site" "$api"
mkdir "$api"
printf stray >"$api/stray"
if play stray-api 949b89f 0c856b9; then fail 'stray API folder was accepted'; fi
grep -F 'web: /srv/keepbreath-contact-api exists but is not a git checkout; move it aside before running the web role' "$last_log" >/dev/null || fail 'stray API failure differs'
test "$(cat "$api/stray")" = stray || fail 'stray API file changed'
test ! -e "$site" || fail 'site was cloned before stray API refusal'
if grep -F 'already exists and is not an empty directory' "$last_log" >/dev/null; then fail 'git handled the stray API folder'; fi
printf 'PASS stray API folder: refused before either clone\n'

mv "$api" "$site"
if play stray-site 949b89f 0c856b9; then fail 'stray site folder was accepted'; fi
grep -F 'web: /srv/keepbreathing exists but is not a git checkout; move it aside before running the web role' "$last_log" >/dev/null || fail 'stray site failure differs'
test ! -e "$api" || fail 'API was cloned before stray site refusal'
printf 'PASS stray site folder: refused before either clone\n'

if ansible-playbook -i localhost, tests/web/role.yml -e "web_container_user=$user" \
  -e 'web_contact_api_ref=0c856b9' >"$work/missing-ref.log" 2>&1; then
  fail 'missing site ref was accepted'
fi
grep -F 'missing required arguments: web_site_ref' "$work/missing-ref.log" >/dev/null || fail 'missing site ref message differs'
printf 'PASS required site ref: argument validation fails\n'

printf 'web driver: all cases passed\n'
