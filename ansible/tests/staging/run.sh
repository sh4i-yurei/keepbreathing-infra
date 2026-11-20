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
if test -e /etc/containers/systemd/cloudflared.container || test -L /etc/containers/systemd/cloudflared.container; then
  fail '/etc/containers/systemd/cloudflared.container already exists'
fi
if podman secret exists cloudflared-tunnel-token; then fail 'cloudflared-tunnel-token already exists'; fi
if podman container exists cloudflared; then fail 'cloudflared container already exists'; fi
for secret in mailpit-smtp-auth mailpit-tls-cert mailpit-tls-key; do
  if podman secret exists "$secret"; then fail "$secret already exists"; fi
done
if podman network exists staging-mail; then fail 'staging-mail already exists'; fi
as_user() {
  (
    cd "$home"
    HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
      XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
  )
}

work=$(mktemp -d)
mapfile -t tunnel_values < <(python3 - "$work" <<'PY'
import base64
import json
import os
from pathlib import Path
import secrets
import sys
import uuid

folder = Path(sys.argv[1])
for label in ('a', 'b'):
    secret = base64.b64encode(os.urandom(32)).decode()
    value = base64.b64encode(json.dumps({'a': secrets.token_hex(16), 't': str(uuid.uuid4()), 's': secret}).encode()).decode()
    path = folder / f'tunnel-{label}.json'
    path.write_text(json.dumps({'staging_tunnel_token': value}))
    path.chmod(0o600)
    print(value)
    print(secret)
PY
)
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
undo_add 'remove driver-created cloudflared' undo_cloudflared
undo_cloudflared() {
  systemctl stop cloudflared.service >/dev/null 2>&1 || true
  rm -f /etc/containers/systemd/cloudflared.container
  systemctl daemon-reload
  podman rm -f cloudflared >/dev/null 2>&1 || true
  podman secret rm cloudflared-tunnel-token >/dev/null 2>&1 || true
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

if ansible-playbook -i localhost, tests/staging/tunnel.yml -e "@$work/tunnel-a.json" --check --diff >"$work/tunnel-fresh-check.log" 2>&1; then
  grep -F "Would replace root's Podman secret cloudflared-tunnel-token" "$work/tunnel-fresh-check.log" >/dev/null || fail 'fresh tunnel check did not predict secret replacement'
  grep -F 'Exec=tunnel --metrics 127.0.0.1:20241 run' "$work/tunnel-fresh-check.log" >/dev/null || fail 'fresh tunnel check did not show Exec'
  test ! -e /etc/containers/systemd/cloudflared.container || fail 'fresh tunnel check created unit'
  ! podman secret exists cloudflared-tunnel-token || fail 'fresh tunnel check created secret'
  ! podman image exists docker.io/cloudflare/cloudflared@sha256:28b1b51bc44446fafe254b37cd12b024f417a4e48a4b3c136620c2b93cdb0064 || fail 'fresh tunnel check pulled image'
  tunnel_fresh_changed=$(changed "$work/tunnel-fresh-check.log" positive)
  printf 'PASS tunnel check mode on a fresh machine: changed=%s, nothing created\n' "$tunnel_fresh_changed"
else
  tail -25 "$work/tunnel-fresh-check.log"
  fail 'fresh tunnel check must pass'
fi

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
install -o "$user" -g "$user" -m 0644 tests/staging/send.py "$home/staging-send.py"
send() {
  local mode=$1 authority=$2
  local -a authority_args=()
  if test "$authority" = yes; then
    authority_args=(--secret staging-ca,type=mount,target=/etc/staging-ca.crt --env SSL_CERT_FILE=/etc/staging-ca.crt)
  fi
  as_user podman run --rm --network keepbreath-net --add-host mailpit.staging:10.89.200.10 \
    "${authority_args[@]}" --mount "type=bind,src=$home/staging-send.py,dst=/t/send.py,ro=true" \
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

tunnel_play() {
  local label=$1 token_file=$2
  shift 2
  last_log="$work/$label.log"
  if ! ansible-playbook -i localhost, tests/staging/tunnel.yml -e "@$token_file" "$@" >"$last_log" 2>&1; then
    tail -40 "$last_log"
    fail "$label dry run must pass"
  fi
}
tunnel_real() {
  local label=$1 token_file=$2
  shift 2
  last_log="$work/$label.log"
  if ansible-playbook -i localhost, tests/staging/tunnel.yml -e "@$token_file" "$@" >"$last_log" 2>&1; then
    fail "$label run passed with a made-up token"
  fi
  if ! grep -F 'cloudflared did not connect to Cloudflare: http://127.0.0.1:20241/ready answered 503 instead of 200 for 60 seconds' "$last_log" >/dev/null; then
    tail -40 "$last_log"
    fail "$label readiness message differs"
  fi
  if ! grep -E 'localhost[[:space:]]*:.*[[:space:]]failed=1[[:space:]].*[[:space:]]rescued=1([[:space:]]|$)' "$last_log" >/dev/null; then
    tail -40 "$last_log"
    fail "$label recap differs"
  fi
}
wait_active() {
  for _ in {1..10}; do
    if test "$(systemctl show -P ActiveState cloudflared.service)" = active; then return; fi
    sleep 1
  done
  fail 'cloudflared.service did not reach active'
}
wait_fresh_active() {
  for _ in {1..120}; do
    if test "$(systemctl show -P ActiveState cloudflared.service)" = active; then
      started=$(systemctl show -P ActiveEnterTimestamp cloudflared.service)
      if test -n "$started" && test $(( $(date +%s) - $(date -d "$started" +%s) )) -lt 10; then return; fi
    fi
    sleep 1
  done
  fail 'cloudflared.service did not reach a fresh active instance'
}
read_tunnel_environment() {
  local expected=$1 pid line
  for _ in {1..5}; do
    wait_active
    pid=$(podman inspect cloudflared --format '{{ .State.Pid }}' 2>/dev/null) || continue
    line=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n '/^TUNNEL_TOKEN=/p') || continue
    if [[ $line == "TUNNEL_TOKEN=$expected" ]]; then return; fi
  done
  fail 'cloudflared environment has the wrong tunnel token'
}

if ansible-playbook -i localhost, tests/staging/tunnel.yml >"$work/tunnel-no-token.log" 2>&1; then fail 'missing tunnel token was accepted'; fi
grep -F 'missing required arguments: staging_tunnel_token' "$work/tunnel-no-token.log" >/dev/null || fail 'missing tunnel token message differs'
! podman secret exists cloudflared-tunnel-token || fail 'missing token created secret'
printf 'PASS a run without a token fails before changing anything\n'

bad_image=localhost:1/staging/no-such-image@sha256:$(printf '0%.0s' {1..64})
if ansible-playbook -i localhost, tests/staging/tunnel.yml -e "@$work/tunnel-a.json" -e "staging_cloudflared_image=$bad_image" >"$work/tunnel-bad-image.log" 2>&1; then fail 'unpullable image was accepted'; fi
grep -F "$bad_image" "$work/tunnel-bad-image.log" >/dev/null || fail 'failed pull did not name image'
test ! -e /etc/containers/systemd/cloudflared.container || fail 'the unit was written before its image was pulled'
! podman secret exists cloudflared-tunnel-token || fail 'the secret was replaced before the image was pulled'
printf 'PASS an image that cannot be pulled fails the run before the unit is written\n'

tunnel_real tunnel-first "$work/tunnel-a.json"
tunnel_first_changed=$(changed "$last_log" positive)
wait_active
ready_status=
for _ in {1..10}; do
  wait_active
  ready_status=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20241/ready) || true
  if test "$ready_status" = 503; then break; fi
  sleep 1
done
test "$ready_status" = 503 || fail "cloudflared /ready answered $ready_status instead of 503"
test "$(stat -c '%u:%g:%a' /etc/containers/systemd/cloudflared.container)" = 0:0:644 || fail 'cloudflared unit owner or mode differs'
token_a_hash=$(python3 - "$work/tunnel-a.json" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.load(open(sys.argv[1]))['staging_tunnel_token'].encode()).hexdigest())
PY
)
test "$(podman secret inspect cloudflared-tunnel-token --format '{{ index .Spec.Labels "sha256" }}')" = "$token_a_hash" || fail 'tunnel secret label differs from token A'
read_tunnel_environment "${tunnel_values[0]}"
printf 'PASS a made-up token fails the readiness check with the role message: changed=%s\n' "$tunnel_first_changed"

wait_active
python3 - "$work/tunnel-a.json" <<'PY' || fail 'token appeared on a command line or in a unit file'
import base64, json, pathlib, sys
token = json.load(open(sys.argv[1]))['staging_tunnel_token']
part = json.loads(base64.b64decode(token))['s']
found = False
for path in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
    try:
        data = path.read_bytes()
    except OSError:
        continue
    assert token.encode() not in data and part.encode() not in data, f'token on command line {path}'
    if data.split(b'\0') == [b'cloudflared', b'tunnel', b'--metrics', b'127.0.0.1:20241', b'run', b'']:
        found = True
assert found, 'cloudflared command line was not searched'
for folder in ('/etc/containers/systemd', '/run/systemd/generator'):
    for path in pathlib.Path(folder).rglob('*'):
        if path.is_file():
            data = path.read_bytes()
            assert token.encode() not in data and part.encode() not in data, f'token in {path}'
PY
as_user cat /run/systemd/generator/cloudflared.service >"$work/tunnel-generated-unit.txt" || fail 'stgtest cannot read generated tunnel unit'
grep -F 'cloudflared-tunnel-token,type=env,target=TUNNEL_TOKEN' "$work/tunnel-generated-unit.txt" >/dev/null || fail 'generated unit lacks secret reference'
printf 'PASS the token is on no command line and in no unit file\n'

environment_refused=
for _ in {1..5}; do
  wait_active
  tunnel_pid=$(podman inspect cloudflared --format '{{ .State.Pid }}' 2>/dev/null) || continue
  if as_user cat "/proc/$tunnel_pid/environ" >"$work/tunnel-env-read.log" 2>"$work/tunnel-env-read-error.log"; then
    fail 'stgtest read cloudflared environment'
  fi
  if grep -F 'No such file' "$work/tunnel-env-read-error.log" >/dev/null; then continue; fi
  grep -F 'Permission denied' "$work/tunnel-env-read-error.log" >/dev/null || fail "environment refusal differs: $(head -1 "$work/tunnel-env-read-error.log")"
  test ! -s "$work/tunnel-env-read.log" || fail 'stgtest printed part of cloudflared environment'
  environment_refused=yes
  break
done
test -n "$environment_refused" || fail 'stgtest never met a running cloudflared'
printf "PASS the account cannot read cloudflared's environment\n"

wait_fresh_active
HOME=/root XDG_CONFIG_HOME=/root/.config tunnel_real tunnel-second "$work/tunnel-a.json" -e 'ansible_become_flags=-E -S -n'
test "$(changed "$last_log" zero)" = 0
printf "PASS the second tunnel run, with sudo keeping the caller's HOME and XDG_CONFIG_HOME: changed=0\n"
wait_fresh_active
tunnel_play tunnel-repeat-check "$work/tunnel-a.json" --check --diff
test "$(changed "$last_log" zero)" = 0
printf 'PASS tunnel check mode after a run: changed=0\n'

printf wrong | podman secret create --replace --label sha256=wrong cloudflared-tunnel-token - >/dev/null
tunnel_play tunnel-wrong-check "$work/tunnel-b.json" --check --diff
tunnel_wrong_changed=$(changed "$last_log" positive)
grep -F "Would replace root's Podman secret cloudflared-tunnel-token" "$last_log" >/dev/null || fail 'wrong tunnel secret dry run lacked prediction'
test "$(podman secret inspect cloudflared-tunnel-token --format '{{ index .Spec.Labels "sha256" }}')" = wrong || fail 'wrong tunnel secret dry run changed label'
printf 'PASS a dry run reports the wrong tunnel secret and leaves it: changed=%s\n' "$tunnel_wrong_changed"
tunnel_real tunnel-new-token "$work/tunnel-b.json"
tunnel_new_changed=$(changed "$last_log" positive)
token_b_hash=$(python3 - "$work/tunnel-b.json" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.load(open(sys.argv[1]))['staging_tunnel_token'].encode()).hexdigest())
PY
)
test "$(podman secret inspect cloudflared-tunnel-token --format '{{ index .Spec.Labels "sha256" }}')" = "$token_b_hash" || fail 'tunnel secret label differs from token B'
read_tunnel_environment "${tunnel_values[2]}"
printf 'PASS a new token replaces the secret and restarts cloudflared: changed=%s\n' "$tunnel_new_changed"

systemctl stop cloudflared.service
podman secret rm cloudflared-tunnel-token >/dev/null
tunnel_play tunnel-missing-secret-check "$work/tunnel-b.json" --check --diff
grep -F "Would replace root's Podman secret cloudflared-tunnel-token" "$last_log" >/dev/null || fail 'missing tunnel secret dry run lacked prediction'
! podman secret exists cloudflared-tunnel-token || fail 'missing secret dry run restored secret'
tunnel_real tunnel-missing-secret "$work/tunnel-b.json"
test "$(podman secret inspect cloudflared-tunnel-token --format '{{ index .Spec.Labels "sha256" }}')" = "$token_b_hash" || fail 'missing tunnel secret not restored'
wait_active
printf 'PASS a missing tunnel secret: the dry run finishes and a run restores it\n'

rm /etc/containers/systemd/cloudflared.container
systemctl daemon-reload
tunnel_play tunnel-missing-unit-check "$work/tunnel-b.json" --check --diff
changed "$last_log" positive >/dev/null
test ! -e /etc/containers/systemd/cloudflared.container || fail 'missing unit dry run wrote unit'
tunnel_real tunnel-missing-unit "$work/tunnel-b.json"
test -e /etc/containers/systemd/cloudflared.container || fail 'missing tunnel unit not restored'
wait_active
printf 'PASS a missing tunnel unit: the dry run finishes and a run restores it\n'

for index in "${!generated_names[@]}"; do
  if grep -F -- "${generated_values[index]}" "$work"/*.log >/dev/null; then
    fail "${generated_names[index]} appeared in run output"
  fi
done
for value in "${tunnel_values[@]}"; do
  if grep -F -- "$value" "$work"/*.log >/dev/null; then fail 'tunnel token or secret part appeared in run output'; fi
done
printf 'PASS no value in any run output\n'

printf 'staging driver: all cases passed\n'
