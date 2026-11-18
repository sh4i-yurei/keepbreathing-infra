#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if test -e /etc/staging || test -L /etc/staging; then
  fail '/etc/staging already exists'
fi

work=$(mktemp -d)
undo_add 'remove staging driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_add 'remove driver-created staging folder' undo_staging
undo_staging() { if test -d /etc/staging && ! test -L /etc/staging; then rm -rf -- /etc/staging; fi; }
undo_install

play() {
  local label=$1
  shift
  last_log="$work/$label.log"
  if ! ansible-playbook -i localhost, tests/staging/role.yml -e "inputs_path=$work/inputs.json" "$@" >"$last_log" 2>&1; then
    tail -55 "$last_log"
    fail "$label play must pass"
  fi
}
changed() {
  local value
  value=$(sed -n 's/.*localhost[[:space:]]*:.*changed=\([0-9][0-9]*\).*/\1/p' "$1" | tail -1)
  test -n "$value" || fail "$1 has no localhost recap"
  if test "$2" = positive; then
    test "$value" -gt 0 || fail "$1 must report changed above zero"
  else
    test "$value" -eq 0 || fail "$1 must report changed=0"
  fi
  printf '%s' "$value"
}

play fresh-check --check --diff
fresh_changed=$(changed "$last_log" positive)
test ! -e /etc/staging || fail 'fresh check created /etc/staging'
printf 'PASS check mode on a fresh machine: changed=%s, nothing created\n' "$fresh_changed"

play first
first_changed=$(changed "$last_log" positive)
printf 'PASS first run: changed=%s\n' "$first_changed"

python3 - <<'PY' || fail 'modes and values'
from pathlib import Path
import re
import stat

folder = Path('/etc/staging')
info = folder.stat()
assert stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == info.st_gid == 0
for name in ('redis-password', 'altcha-hmac-key', 'smtp-password', 'ca.key', 'mailpit.key', 'origin.key'):
    info = (folder / name).stat()
    assert stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == info.st_gid == 0, name
for name in ('redis-password', 'altcha-hmac-key', 'smtp-password'):
    assert re.fullmatch(r'[A-Za-z0-9]{40}', (folder / name).read_text()), name
PY
printf 'PASS modes and values\n'

openssl x509 -in /etc/staging/ca.crt -noout -text >"$work/ca.txt"
openssl x509 -in /etc/staging/mailpit.crt -noout -text >"$work/mailpit.txt"
openssl x509 -in /etc/staging/origin.crt -noout -text >"$work/origin.txt"
grep -F 'X509v3 Basic Constraints: critical' "$work/ca.txt" >/dev/null || fail 'CA constraints are not critical'
grep -F 'CA:TRUE' "$work/ca.txt" >/dev/null || fail 'CA is not an authority'
grep -F 'X509v3 Key Usage: critical' "$work/ca.txt" >/dev/null || fail 'CA key usage is not critical'
grep -F 'Certificate Sign, CRL Sign' "$work/ca.txt" >/dev/null || fail 'CA key usage differs'
grep -F 'DNS:mailpit.staging' "$work/mailpit.txt" >/dev/null || fail 'Mailpit name differs'
grep -F 'TLS Web Server Authentication' "$work/mailpit.txt" >/dev/null || fail 'Mailpit serverAuth differs'
grep -F 'X509v3 Authority Key Identifier' "$work/mailpit.txt" >/dev/null || fail 'Mailpit authority identifier is absent'
grep -F 'DNS:*.keepbreath.ing, DNS:keepbreath.ing' "$work/origin.txt" >/dev/null || fail 'origin names differ'
openssl verify -CAfile /etc/staging/ca.crt /etc/staging/mailpit.crt /etc/staging/origin.crt >"$work/verify.txt" || fail 'certificate chain does not verify'
grep -Fx '/etc/staging/mailpit.crt: OK' "$work/verify.txt" >/dev/null || fail 'Mailpit certificate does not verify'
grep -Fx '/etc/staging/origin.crt: OK' "$work/verify.txt" >/dev/null || fail 'origin certificate does not verify'
printf 'PASS certificates\n'

python3 tests/staging/strict_verify.py /etc/staging
python3 - "$work/inputs.json" <<'PY' || fail 'staging_web_inputs differs from files'
import json
from pathlib import Path
import sys

actual = json.loads(Path(sys.argv[1]).read_text())
folder = Path('/etc/staging')
expected = {
    'web_redis_password': (folder / 'redis-password').read_text(),
    'web_altcha_hmac_key': (folder / 'altcha-hmac-key').read_text(),
    'web_smtp_host': 'mailpit.staging',
    'web_smtp_host_address': '10.89.200.10',
    'web_smtp_port': 1025,
    'web_smtp_user': 'staging',
    'web_smtp_password': (folder / 'smtp-password').read_text(),
    'web_origin_certificate': (folder / 'origin.crt').read_text(),
    'web_origin_key': (folder / 'origin.key').read_text(),
}
assert actual == expected
PY
printf 'PASS staging_web_inputs\n'

play second
test "$(changed "$last_log" zero)" = 0
printf 'PASS second run: changed=0\n'
play repeat-check --check --diff
test "$(changed "$last_log" zero)" = 0
printf 'PASS check mode after a run: changed=0\n'

cp /etc/staging/mailpit.key "$work/mailpit.key"
rm /etc/staging/mailpit.key
play missing-key-check --check --diff
test ! -e /etc/staging/mailpit.key || fail 'missing-key check created mailpit.key'
cp "$work/mailpit.key" /etc/staging/mailpit.key
chmod 0600 /etc/staging/mailpit.key
printf 'PASS check mode with a missing leaf key\n'

redis_before=$(cat /etc/staging/redis-password)
printf %s 'KeptAltchaValue0123456789abcdefghijKLMNO' >/etc/staging/altcha-hmac-key
play survival
test "$(changed "$last_log" zero)" = 0
test "$(cat /etc/staging/redis-password)" = "$redis_before" || fail 'redis-password changed'
test "$(cat /etc/staging/altcha-hmac-key)" = 'KeptAltchaValue0123456789abcdefghijKLMNO' || fail 'altcha-hmac-key changed'
python3 - "$work/inputs.json" <<'PY' || fail 'web inputs did not keep the planted ALTCHA value'
import json
from pathlib import Path
import sys
assert json.loads(Path(sys.argv[1]).read_text())['web_altcha_hmac_key'] == 'KeptAltchaValue0123456789abcdefghijKLMNO'
PY
if grep -F 'KeptAltchaValue0123456789abcdefghijKLMNO' "$work"/*.log >/dev/null; then
  fail 'planted altcha-hmac-key appeared in run output'
fi
printf 'PASS an existing value survives\n'

for name in redis-password altcha-hmac-key smtp-password; do
  value=$(cat "/etc/staging/$name")
  if grep -F -- "$value" "$work"/*.log >/dev/null; then fail "$name appeared in run output"; fi
done
printf 'PASS no value in any run output\n'

printf 'staging driver: all cases passed\n'
