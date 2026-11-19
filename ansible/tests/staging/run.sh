#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

user=stgtest
home=/home/$user
if id -u "$user" >/dev/null 2>&1; then fail 'stgtest already exists'; fi
if test -e /etc/staging || test -L /etc/staging; then
  fail '/etc/staging already exists'
fi
for unit in /etc/containers/systemd/staging-mail.network /etc/containers/systemd/mailpit.container; do
  if test -e "$unit" || test -L "$unit"; then fail "$unit already exists"; fi
done
for secret in mailpit-smtp-auth mailpit-tls-cert mailpit-tls-key; do
  if podman secret exists "$secret"; then fail "$secret already exists"; fi
done
if podman network exists staging-mail; then fail 'staging-mail already exists'; fi
as_user() {
  runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" "$@"
}

work=$(mktemp -d)
undo_add 'remove staging driver work' undo_work
undo_work() { rm -rf -- "$work"; }
undo_add 'remove driver-created staging folder' undo_staging
undo_staging() { if test -d /etc/staging && ! test -L /etc/staging; then rm -rf -- /etc/staging; fi; }
undo_add 'remove driver-created staging account' undo_account
undo_account() {
  if id -u "$user" >/dev/null 2>&1; then
    as_user podman network rm keepbreath-net >/dev/null 2>&1 || true
    runner_undo_account "$user" >"$work/account-cleanup.log" 2>&1 || { cat "$work/account-cleanup.log" >&2; return 1; }
  fi
}
undo_add 'remove driver-created Mailpit' undo_mailpit
undo_mailpit() {
  systemctl stop mailpit.service >/dev/null 2>&1 || true
  rm -f /etc/containers/systemd/mailpit.container /etc/containers/systemd/staging-mail.network
  systemctl daemon-reload
  podman rm -f mailpit >/dev/null 2>&1 || true
  podman network rm staging-mail >/dev/null 2>&1 || true
  podman secret rm mailpit-smtp-auth mailpit-tls-cert mailpit-tls-key >/dev/null 2>&1 || true
}
undo_install
runner_save_environment
useradd -m "$user"
loginctl enable-linger "$user"
systemctl start "user@$(id -u "$user").service"

play() {
  local label=$1
  shift
  last_log="$work/$label.log"
  if ! ansible-playbook -i localhost, tests/staging/role.yml -e "inputs_path=$work/inputs.json" -e "staging_container_user=$user" "$@" >"$last_log" 2>&1; then
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
test ! -e /etc/containers/systemd/mailpit.container || fail 'fresh check created Mailpit unit'
test ! -e /etc/containers/systemd/staging-mail.network || fail 'fresh check created Mailpit network unit'
test ! -e "$home/.config/containers/systemd/contact-worker.container.d" || fail 'fresh check created worker drop-in folder'
printf 'PASS check mode on a fresh machine: changed=%s, nothing created\n' "$fresh_changed"

play first
first_changed=$(changed "$last_log" positive)
printf 'PASS first run: changed=%s\n' "$first_changed"
generated_names=(redis-password altcha-hmac-key smtp-password)
generated_values=()
for name in "${generated_names[@]}"; do
  generated_values+=("$(cat "/etc/staging/$name")")
done

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

systemctl is-active mailpit.service | grep -Fx active >/dev/null || fail 'mailpit.service must be active'
for unit in /etc/containers/systemd/staging-mail.network /etc/containers/systemd/mailpit.container; do
  test "$(stat -c '%u:%g:%a' "$unit")" = 0:0:644 || fail "$unit has wrong ownership or mode"
done
printf 'PASS mailpit.service active\n'

dropin="$home/.config/containers/systemd/contact-worker.container.d/60-staging-ca.conf"
test "$(stat -c '%u:%a' "$dropin")" = "$(id -u "$user"):644" || fail "the drop-in is not the account's"
cat >"$work/expected-dropin" <<'EOF'
[Container]
Secret=staging-ca,type=mount,target=/etc/staging/ca.crt
Environment=SSL_CERT_FILE=/etc/staging/ca.crt
EOF
cmp "$work/expected-dropin" "$dropin" || fail 'worker drop-in differs'
printf 'PASS worker drop-in\n'

cat >"$home/.config/containers/systemd/contact-worker.container" <<'EOF'
[Container]
Image=docker.io/library/python:3.13-alpine@sha256:42825e7ec3437b3bce923c237484eb23d32128476e18307d2f48951bf86f1db2
Network=keepbreath-net
[Install]
WantedBy=default.target
EOF
chown "$user:$user" "$home/.config/containers/systemd/contact-worker.container"
as_user /usr/libexec/podman/quadlet -dryrun -user >"$work/quadlet.log" 2>&1 || fail 'worker Quadlet dry run failed'
grep -F 'staging-ca,type=mount,target=/etc/staging/ca.crt' "$work/quadlet.log" >/dev/null || fail 'worker Quadlet did not mount authority'
grep -F 'SSL_CERT_FILE=/etc/staging/ca.crt' "$work/quadlet.log" >/dev/null || fail 'worker Quadlet did not set SSL_CERT_FILE'
rm "$home/.config/containers/systemd/contact-worker.container"
printf 'PASS worker Quadlet authority\n'

as_user podman network create keepbreath-net >"$work/worker-network.log"
as_user podman pull docker.io/library/python:3.13-alpine@sha256:42825e7ec3437b3bce923c237484eb23d32128476e18307d2f48951bf86f1db2 >"$work/python-pull.log"
printf %s "${generated_values[2]}" >"$home/staging-pw"
chown "$user:$user" "$home/staging-pw"
chmod 0600 "$home/staging-pw"
send() {
  local mode=$1 authority=$2
  local -a authority_args=()
  if test "$authority" = yes; then
    authority_args=(--secret staging-ca,type=mount,target=/etc/staging-ca.crt --env SSL_CERT_FILE=/etc/staging-ca.crt)
  fi
  as_user podman run --rm --network keepbreath-net --add-host mailpit.staging:10.89.200.10 \
    "${authority_args[@]}" --mount "type=bind,src=$PWD/tests/staging/send.py,dst=/t/send.py,ro=true" \
    --mount "type=bind,src=$home/staging-pw,dst=/t/pw,ro=true" \
    docker.io/library/python:3.13-alpine@sha256:42825e7ec3437b3bce923c237484eb23d32128476e18307d2f48951bf86f1db2 \
    python /t/send.py "$mode"
}
test "$(send login yes)" = 'login: SENT' || fail 'login send must succeed'
nologin_line=$(send nologin yes)
[[ $nologin_line == "nologin: SMTPSenderRefused: (530, b'5.7.0 Authentication required"* ]] || fail 'no-login send must be refused'
send login no | grep -F 'CERTIFICATE_VERIFY_FAILED' >/dev/null || fail 'untrusted send must fail certificate verification'
printf 'PASS the account sends only with the login and the authority\n'

if as_user podman network inspect staging-mail >"$work/network-inspect.log" 2>&1; then fail 'the account joined staging-mail'; fi
grep -F 'network not found' "$work/network-inspect.log" >/dev/null || fail 'the account network refusal differs'
if as_user podman run --rm --network host docker.io/library/python:3.13-alpine@sha256:42825e7ec3437b3bce923c237484eb23d32128476e18307d2f48951bf86f1db2 python -c 'import urllib.request; urllib.request.urlopen("http://10.89.200.10:8025/api/v1/info", timeout=3)' >"$work/ui.log" 2>&1; then fail 'the account read Mailpit UI'; fi
podman exec mailpit wget -qO- http://127.0.0.1:8025/api/v1/messages >"$work/mailpit-info.json" || fail 'Mailpit messages request failed'
python3 - "$work/mailpit-info.json" <<'PY' || fail 'Mailpit did not catch one message'
import json
import sys
assert json.load(open(sys.argv[1]))['messages_count'] == 1
PY
printf 'PASS the account can neither read Mailpit nor join its network\n'

printf wrong | podman secret create --replace --label sha256=wrong mailpit-smtp-auth - >/dev/null
play relabel-check --check --diff
relabel_check_changed=$(changed "$last_log" positive)
grep -F "Would replace root's Podman secret mailpit-smtp-auth" "$last_log" >/dev/null || fail 'dry run did not report wrong secret'
podman secret inspect mailpit-smtp-auth --format '{{ index .Spec.Labels "sha256" }}' | grep -Fx wrong >/dev/null || fail 'dry run changed root secret'
printf 'PASS a dry run reports the wrong secret and leaves it: changed=%s\n' "$relabel_check_changed"
before_restart=$(systemctl show -P InvocationID mailpit.service)
play relabel
relabel_changed=$(changed "$last_log" positive)
test "$(systemctl show -P InvocationID mailpit.service)" != "$before_restart" || fail 'Mailpit did not restart after secret replacement'
test "$(send login yes)" = 'login: SENT' || fail 'login did not recover after secret replacement'
printf 'PASS a wrong secret is replaced and Mailpit restarted: changed=%s\n' "$relabel_changed"
play relabel-second
test "$(changed "$last_log" zero)" = 0
printf 'PASS the next run: changed=0\n'

HOME=/root XDG_CONFIG_HOME=/root/.config play kept-home -e 'ansible_become_flags=-E -S -n'
test "$(changed "$last_log" zero)" = 0
printf "PASS a run whose sudo keeps the caller's HOME and XDG_CONFIG_HOME: changed=0\n"

podman secret rm mailpit-tls-key >/dev/null
play missing-secret-check --check --diff
if podman secret exists mailpit-tls-key; then fail 'dry run restored a missing secret'; fi
before_restart=$(systemctl show -P InvocationID mailpit.service)
play missing-secret
missing_changed=$(changed "$last_log" positive)
test "$(systemctl show -P InvocationID mailpit.service)" != "$before_restart" || fail 'Mailpit did not restart after secret restoration'
podman secret exists mailpit-tls-key || fail 'missing secret was not restored'
test "$(send login yes)" = 'login: SENT' || fail 'login failed after secret restoration'
printf 'PASS a missing Mailpit secret: the dry run finishes and a run restores it: changed=%s\n' "$missing_changed"

if ansible-playbook -i localhost, tests/staging/role.yml -e "inputs_path=$work/inputs.json" -e staging_container_user=nosuchuser >"$work/missing-account.log" 2>&1; then fail 'missing account was accepted'; fi
grep -F 'staging_container_user nosuchuser must exist' "$work/missing-account.log" >/dev/null || fail 'missing account message differs'
play missing-account-check -e staging_container_user=nosuchuser --check --diff
printf 'PASS a missing account fails a run and not a dry run\n'

rm -rf "$home/.config/containers/systemd/contact-worker.container.d"
mkdir "$work/root-only"
ln -s "$work/root-only" "$home/.config/containers/systemd/contact-worker.container.d"
if ansible-playbook -i localhost, tests/staging/role.yml -e "inputs_path=$work/inputs.json" -e "staging_container_user=$user" >"$work/link.log" 2>&1; then fail 'planted link was accepted'; fi
test ! -e "$work/root-only/60-staging-ca.conf" || fail 'planted link wrote as root'
rm "$home/.config/containers/systemd/contact-worker.container.d"
printf 'PASS a planted link fails the run instead of writing as root\n'

for index in "${!generated_names[@]}"; do
  if grep -F -- "${generated_values[index]}" "$work"/*.log >/dev/null; then
    fail "${generated_names[index]} appeared in run output"
  fi
done
printf 'PASS no value in any run output\n'

printf 'staging driver: all cases passed\n'
