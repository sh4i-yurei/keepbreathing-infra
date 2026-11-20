#!/usr/bin/env bash
set -euo pipefail

source tests/lib/undo.sh
source tests/lib/runner.sh

user=webtest
site=/srv/keepbreathing
api=/srv/keepbreath-contact-api
home=/home/$user
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

if id -u "$user" >/dev/null 2>&1; then fail 'webtest already exists'; fi
if test -e "$site" || test -L "$site"; then fail '/srv/keepbreathing already exists'; fi
if test -e "$api" || test -L "$api"; then fail '/srv/keepbreath-contact-api already exists'; fi
sysctl_file=/etc/sysctl.d/99-podman-ports.conf
deploy_site=/usr/local/bin/deploy-site
keys_dir=/etc/ssh/authorized_keys
key_file=$keys_dir/$user
for path in "$sysctl_file" "$deploy_site" "$key_file"; do
  if test -e "$path" || test -L "$path"; then fail "$path already exists"; fi
done
for service in http https; do
  if firewall-cmd --zone=public --query-service="$service" >/dev/null 2>&1; then fail "firewalld already allows $service"; fi
  if firewall-cmd --permanent --zone=public --query-service="$service" >/dev/null 2>&1; then fail "firewalld already allows $service permanently"; fi
done
port_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start)
keys_dir_existed=false
if test -e "$keys_dir" || test -L "$keys_dir"; then keys_dir_existed=true; fi

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
undo_add 'remove the web host pieces' undo_host
undo_host() {
  rm -f -- "$sysctl_file" "$deploy_site" "$key_file"
  if ! $keys_dir_existed; then rm -rf -- "$keys_dir"; fi
  sysctl -q -w "net.ipv4.ip_unprivileged_port_start=$port_start"
  for service in http https; do
    firewall-cmd --zone=public --remove-service="$service" >/dev/null 2>&1
    firewall-cmd --permanent --zone=public --remove-service="$service" >/dev/null 2>&1
  done
}
undo_install
runner_save_environment

as_user() {
  (
    cd "$home"
    HOME="$home" USER="$user" LOGNAME="$user" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
      XDG_CONFIG_HOME="$home/.config" runuser -u "$user" -- "$@"
  )
}

python3 - "$work" <<'PY' || fail 'could not make the test pairs and deploy key'
import datetime, json, pathlib, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.x509.oid import NameOID

work = pathlib.Path(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
pairs = {}
for label in ('a', 'b'):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f'web-test-{label}')])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=30))
        .sign(key, hashes.SHA256())
    )
    pem = certificate.public_bytes(serialization.Encoding.PEM).decode()
    key_pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    (work / f'{label}.pem').write_text(pem)
    (work / f'{label}.key').write_text(key_pem)
    pairs[label] = (pem, key_pem)
public = ed25519.Ed25519PrivateKey.generate().public_key().public_bytes(
    serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
).decode()
line = f'from="10.128.0.5",restrict,command="/usr/local/bin/deploy-site" {public} deploy-test'
(work / 'deploy-key.line').write_text(line + '\n')
for label, (pem, key_pem) in (('a', pairs['a']), ('b', pairs['b']), ('mixed', (pairs['a'][0], pairs['b'][1]))):
    (work / f'inputs-{label}.json').write_text(json.dumps({
        'web_origin_certificate': pem,
        'web_origin_key': key_pem,
        'web_firewall_services': ['http', 'https'],
        'web_deploy_key': line,
    }))
PY
key_a_line=$(sed -n 2p "$work/a.key")
key_b_line=$(sed -n 2p "$work/b.key")

secret_inputs=(-e 'web_redis_password=Rp4ss-w0rd.x' -e 'web_altcha_hmac_key=altcha-key-1'
  -e '{"web_smtp_password": "smtp p@ss"}')
pair_inputs=(-e "@$work/inputs-a.json")

play() {
  local label=$1 site_ref=$2 api_ref=$3
  shift 3
  last_log="$work/$label.log"
  ansible-playbook -i localhost, tests/web/role.yml \
    -e "web_container_user=$user" -e "web_site_ref=$site_ref" \
    -e "web_contact_api_ref=$api_ref" \
    -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587' \
    -e 'web_smtp_user=contact@keepbreath.ing' \
    -e 'web_smtp_host_address=10.128.0.4' "${secret_inputs[@]}" "${pair_inputs[@]}" "$@" >"$last_log" 2>&1
}
no_copies() {
  local log=$1 value
  shift
  for value in "$@"; do
    if grep -F -- "$value" "$log" >/dev/null; then fail "$log holds a copy of $value"; fi
  done
}
expect_secret() {
  as_user podman secret inspect --showsecret "$1" >"$work/secret.json" || fail "$1 could not be inspected"
  python3 - "$work/secret.json" "$2" <<'PY' || fail "$1 stored value differs"
import json, sys
assert json.load(open(sys.argv[1]))[0]['SecretData'] == sys.argv[2]
PY
  rm -f -- "$work/secret.json"
}
expect_five() {
  expect_secret kb-redis-conf $'requirepass Rp4ss-w0rd.x\n'
  expect_secret kb-rediscli-auth 'Rp4ss-w0rd.x'
  expect_secret kb-broker-url 'redis://:Rp4ss-w0rd.x@keepbreath-redis:6379/0'
  expect_secret kb-altcha-key "$1"
  expect_secret kb-smtp-pass 'smtp p@ss'
}
written_is() {
  python3 - "$last_log" "$1" <<'PY' || fail "web_secrets_written was not [$1]"
import json, pathlib, re, sys
log, want = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
task = re.search(r'TASK \[Show which secrets the role wrote\][^\n]*\n(.*?)(?=\nTASK \[|\nPLAY RECAP)', log, re.S)
assert task, 'no debug task'
messages = re.findall(r'^\s*"msg": (".*")$', task.group(1), re.M)
assert [json.loads(message) for message in messages] == ['written: ' + want], messages
PY
}
recap() {
  grep -Eq "localhost[[:space:]]+:.*changed=$2 .*failed=0" "$1" || {
    tail -45 "$1"
    fail "$1 recap must have changed=$2 and failed=0"
  }
}
changed_task() {
  python3 - "$1" "$2" <<'PY' || fail "$2 did not report changed"
import pathlib, re, sys
log, title = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
task = re.search(r'TASK \[web : ' + re.escape(title) + r'\][^\n]*\n(.*?)(?=\nTASK \[|\nPLAY RECAP)', log, re.S)
assert task and re.search(r'^changed: \[localhost\]', task.group(1), re.M)
PY
}
head_at() {
  runuser -u "$user" -- git -C "$1" rev-parse --short=7 HEAD
}
expect_head() {
  local actual
  actual=$(head_at "$1")
  test "$actual" = "$2" || fail "$1 HEAD was $actual, expected $2"
}
service_open() {
  local name=$1
  shift
  firewall-cmd "$@" --zone=public --query-service="$name" >/dev/null 2>&1
}
expect_host_untouched() {
  test "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" = "$port_start" || fail "$1 changed the live port boundary"
  for path in "$sysctl_file" "$deploy_site" "$key_file"; do
    if test -e "$path" || test -L "$path"; then fail "$1 created $path"; fi
  done
  for service in http https; do
    if service_open "$service"; then fail "$1 opened $service at runtime"; fi
    if service_open "$service" --permanent; then fail "$1 opened $service permanently"; fi
  done
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

if ansible localhost -i localhost, -c local --playbook-dir tests/web \
  -m ansible.builtin.include_role -a name=web \
  -e 'web_container_user=webabsent' -e 'web_site_ref=949b89f' \
  -e 'web_contact_api_ref=0c856b9' \
  -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587' \
  -e 'web_smtp_user=contact@keepbreath.ing' \
  -e 'web_smtp_host_address=10.128.0.4' "${secret_inputs[@]}" "${pair_inputs[@]}" >"$work/missing-account.log" 2>&1; then
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

for entry in 'name=web tasks_from=account' 'name=baseline tasks_from=container-account'; do
  extra=(-e "web_container_user=$user" -e "baseline_container_user=$user"
    -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587'
    -e 'web_smtp_user=contact@keepbreath.ing'
    -e 'web_smtp_host_address=10.128.0.4' "${secret_inputs[@]}" "${pair_inputs[@]}")
  if ! ansible localhost -i localhost, -c local --playbook-dir tests/web \
    -m ansible.builtin.include_role -a "$entry" "${extra[@]}" \
    >"$work/account-setup.log" 2>&1; then
    tail -45 "$work/account-setup.log"
    fail "account setup failed: $entry"
  fi
done
if ! play account-check 949b89f 0c856b9 --check --diff; then
  tail -45 "$last_log"
  fail 'account check failed'
fi
for prediction in \
  'Would clone https://github.com/sh4i-yurei/keepbreathing.git at 949b89f into /srv/keepbreathing' \
  'Would clone https://github.com/sh4i-yurei/keepbreath-contact-api.git at 0c856b9 into /srv/keepbreath-contact-api' \
  'Would create keepbreath-net' \
  'Would write kb-redis-conf' 'Would write kb-rediscli-auth' 'Would write kb-broker-url' \
  'Would write kb-altcha-key' 'Would write kb-smtp-pass'; do
  grep -F "$prediction" "$last_log" >/dev/null || fail "missing prediction: $prediction"
done
no_copies "$last_log" 'Rp4ss-w0rd.x' 'altcha-key-1' 'smtp p@ss'
for task in "Make the account's Quadlet folder" "Make the worker's drop-in folder" "Write the worker's relay drop-in" \
  'Set the unprivileged port boundary' 'Open the listed firewall services' 'Write the deploy key'; do
  changed_task "$last_log" "$task"
done
expect_host_untouched 'account check'
test ! -e "$site" && test ! -e "$api" || fail 'account check created a checkout'
if as_user podman network inspect keepbreath-net >"$work/missing-network.json" 2>&1; then
  fail 'account check created the network'
else
  test "$?" = 125 || fail 'missing network inspect did not exit 125'
fi
test ! -e "$home/.config/containers/systemd/contact-worker.container.d" || fail 'account check created the drop-in folder'
as_user podman secret ls --quiet >"$work/secrets-after-check.log" || fail 'podman secret ls failed after the account check'
test ! -s "$work/secrets-after-check.log" || fail 'account check created a secret'
printf 'PASS account check: clones, network and drop-in predicted without writes\n'

as_user podman network create --subnet 10.89.0.0/24 --gateway 10.89.0.1 keepbreath-net >"$work/network-create.log"
as_user podman network inspect keepbreath-net >"$work/network-before.json"
network_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["id"])' "$work/network-before.json")

if ! play first 949b89f 0c856b9; then tail -45 "$last_log"; fail 'first run failed'; fi
test "$(grep -c "^$user:" /etc/subuid)" = 1 || fail 'subuid entries differ'
test "$(grep -c "^$user:" /etc/subgid)" = 1 || fail 'subgid entries differ'
for path in "$site" "$api"; do
  test "$(stat -c '%a %U:%G' "$path")" = '755 webtest:webtest' || fail "$path ownership or mode differs"
done
expect_head "$site" 949b89f
expect_head "$api" 0c856b9
as_user podman network inspect keepbreath-net >"$work/network-after.json"
python3 - "$work/network-after.json" "$network_id" <<'PY' || fail 'matching network changed'
import json, sys
network = json.load(open(sys.argv[1]))[0]
assert network['id'] == sys.argv[2]
assert network['subnets'] == [{'subnet': '10.89.0.0/24', 'gateway': '10.89.0.1'}]
assert network['dns_enabled'] is True
PY
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd")" = '700 webtest:webtest' || fail 'Quadlet folder metadata differs'
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd/contact-worker.container.d")" = '755 webtest:webtest' || fail 'drop-in folder metadata differs'
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf")" = '644 webtest:webtest' || fail 'relay drop-in metadata differs'
cmp -s "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf" <(printf '[Container]\nEnvironment=CONTACT_SMTP_HOST=mail.keepbreath.ing\nEnvironment=CONTACT_SMTP_PORT=2587\nEnvironment=CONTACT_SMTP_USER=contact@keepbreath.ing\nAddHost=mail.keepbreath.ing:10.128.0.4\n') || fail 'relay drop-in bytes differ'
printf 'PASS first run: account, subordinate IDs, paths and refs\n'
expect_five 'altcha-key-1'
for name in kb-redis-conf kb-rediscli-auth kb-broker-url kb-altcha-key kb-smtp-pass; do
  as_user podman secret inspect "$name" >"$work/secret-meta.json" || fail "$name could not be inspected"
  python3 - "$work/secret-meta.json" <<'PY' || fail "$name driver is not file"
import json, sys
assert json.load(open(sys.argv[1]))[0]['Spec']['Driver']['Name'] == 'file'
PY
done
printf 'PASS first run: five secrets stored byte for byte with the file driver\n'

test "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" = 80 || fail 'live port boundary is not 80'
grep -Fx 'net.ipv4.ip_unprivileged_port_start=80' "$sysctl_file" >/dev/null || fail "$sysctl_file lacks the port boundary line"
for service in http https; do
  service_open "$service" || fail "$service is not open"
  service_open "$service" --permanent || fail "$service is not open permanently"
done
certs=$site/deploy/certs
test "$(stat -c '%a %U:%G' "$certs")" = '750 webtest:webtest' || fail 'certificate folder metadata differs'
test "$(stat -c '%a %U:%G' "$certs/origin.pem")" = '644 webtest:webtest' || fail 'origin.pem metadata differs'
test "$(stat -c '%a %U:%G' "$certs/origin.key")" = '600 webtest:webtest' || fail 'origin.key metadata differs'
cmp -s "$certs/origin.pem" "$work/a.pem" || fail 'origin.pem differs from pair a'
cmp -s "$certs/origin.key" "$work/a.key" || fail 'origin.key differs from pair a'
test "$(stat -c '%a %U:%G' "$deploy_site")" = '755 root:root' || fail 'deploy-site metadata differs'
cmp -s "$deploy_site" "$site/deploy/deploy-site.sh" || fail 'deploy-site differs from the checkout'
test "$(stat -c '%a %U:%G' "$keys_dir")" = '755 root:root' || fail 'key folder metadata differs'
test "$(stat -c '%a %U:%G' "$key_file")" = '644 root:root' || fail 'deploy key file metadata differs'
cmp -s "$key_file" "$work/deploy-key.line" || fail 'deploy key file differs from the line'
printf 'PASS first run: port boundary, firewall, certificate, deploy-site and deploy key\n'

mkdir "$work/quadlet"
cp -a "$api/deploy/quadlet/." "$work/quadlet/"
cp -a "$home/.config/containers/systemd/contact-worker.container.d" "$work/quadlet/"
chown -R "$user:$user" "$work/quadlet"
chmod 755 "$work"
if ! as_user env "QUADLET_UNIT_DIRS=$work/quadlet" /usr/libexec/podman/quadlet -dryrun -user >"$work/quadlet.log" 2>&1; then
  tail -45 "$work/quadlet.log"
  fail 'Quadlet dry run failed'
fi
python3 - "$work/quadlet.log" <<'PY' || fail 'Quadlet worker relay flags differ'
import pathlib, shlex, sys
output = pathlib.Path(sys.argv[1]).read_text()
worker = output.split('---contact-worker.service---', 1)[1].split('---', 1)[0]
exec_start = next(line.split('=', 1)[1] for line in worker.splitlines() if line.startswith('ExecStart='))
args = shlex.split(exec_start)
for flag, value in [
    ('--add-host', 'mail.keepbreath.ing:10.128.0.4'),
    ('--env', 'CONTACT_SMTP_HOST=mail.keepbreath.ing'),
    ('--env', 'CONTACT_SMTP_PORT=2587'),
    ('--env', 'CONTACT_SMTP_USER=contact@keepbreath.ing'),
]:
    assert sum(args[index:index + 2] == [flag, value] for index in range(len(args) - 1)) == 1, (flag, value, args)
assert args.count('--add-host') == 1
assert sum(args[index] == '--env' and args[index + 1].startswith('CONTACT_SMTP_') for index in range(len(args) - 1)) == 3
PY
rm -rf -- "$work/quadlet"
printf 'PASS Quadlet: one relay pin and one of each setting\n'

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

as_user sh -c 'printf "[Container]\nEnvironment=SSL_CERT_FILE=/x\n" > "$HOME/.config/containers/systemd/contact-worker.container.d/60-staging-ca.conf"'
other_dropin="$home/.config/containers/systemd/contact-worker.container.d/60-staging-ca.conf"
other_hash=$(sha256sum "$other_dropin" | cut -d' ' -f1)
if ! play no-address 949b89f 0c856b9 -e 'web_smtp_host_address='; then tail -45 "$last_log"; fail 'empty address failed'; fi
recap "$last_log" 1
cmp -s "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf" <(printf '[Container]\nEnvironment=CONTACT_SMTP_HOST=mail.keepbreath.ing\nEnvironment=CONTACT_SMTP_PORT=2587\nEnvironment=CONTACT_SMTP_USER=contact@keepbreath.ing\n') || fail 'empty-address drop-in bytes differ'
test "$(stat -c '%a %U:%G' "$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf")" = '644 webtest:webtest' || fail 'empty-address drop-in metadata differs'
test "$(sha256sum "$other_dropin" | cut -d' ' -f1)" = "$other_hash" || fail 'other drop-in changed'
printf 'PASS empty address: pin removed and other drop-in preserved\n'

relay_dropin="$home/.config/containers/systemd/contact-worker.container.d/50-relay.conf"
relay_hash=$(sha256sum "$relay_dropin" | cut -d' ' -f1)
redis_rule='web: web_redis_password may hold only A-Z, a-z, 0-9 and . _ ~ -, because it goes into the broker URL unencoded (Ansible configuration management decision 69.4)'
if play unsafe-password 949b89f 0c856b9 -e 'web_redis_password=has/slash'; then fail 'unsafe Redis password was accepted'; fi
grep -F "$redis_rule" "$last_log" >/dev/null || fail 'unsafe Redis password message differs'
no_copies "$last_log" 'has/slash'
expect_five 'altcha-key-1'
test "$(sha256sum "$relay_dropin" | cut -d' ' -f1)" = "$relay_hash" || fail 'unsafe Redis password run wrote the relay drop-in'
printf 'PASS unsafe Redis password: refused before any write\n'

if play newline-password 949b89f 0c856b9 -e '{"web_redis_password": "Rp4ss-w0rd.x\n"}'; then
  fail 'Redis password ending in a newline was accepted'
fi
grep -F "$redis_rule" "$last_log" >/dev/null || fail 'Redis password ending in a newline message differs'
no_copies "$last_log" 'Rp4ss-w0rd.x'
expect_five 'altcha-key-1'
test "$(sha256sum "$relay_dropin" | cut -d' ' -f1)" = "$relay_hash" || fail 'Redis password ending in a newline run wrote the relay drop-in'
printf 'PASS Redis password ending in a newline: refused before any write\n'

as_user podman secret rm kb-redis-conf kb-rediscli-auth >"$work/secret-rm.log" || fail 'could not remove the two Redis secrets'
printf 'requirepass Rp4ss-w0rd.x\n' | as_user podman secret create kb-redis-conf - >"$work/secret-hand.log" || fail 'could not make kb-redis-conf by hand'
printf %s 'Rp4ss-w0rd.x' | as_user podman secret create kb-rediscli-auth - >>"$work/secret-hand.log" || fail 'could not make kb-rediscli-auth by hand'
if ! play hand-made 949b89f 0c856b9; then tail -45 "$last_log"; fail 'run over secrets made by hand failed'; fi
written_is ''
expect_five 'altcha-key-1'
printf 'PASS secrets made by hand: none written\n'

if ! play changed-key-check 949b89f 0c856b9 --check --diff -e 'web_altcha_hmac_key=altcha-key-2'; then
  tail -45 "$last_log"
  fail 'changed key check failed'
fi
python3 - "$last_log" <<'PY' || fail 'changed key check predicted other writes'
import pathlib, re, sys
predicted = re.findall(r'Would write ([^"\s]+)', pathlib.Path(sys.argv[1]).read_text())
assert predicted == ['kb-altcha-key'], predicted
PY
expect_secret kb-altcha-key 'altcha-key-1'
no_copies "$last_log" 'Rp4ss-w0rd.x' 'altcha-key-1' 'altcha-key-2' 'smtp p@ss'
printf 'PASS changed key in check mode: predicted alone, not written\n'

if ! play changed-key 949b89f 0c856b9 -e 'web_altcha_hmac_key=altcha-key-2'; then tail -45 "$last_log"; fail 'changed key run failed'; fi
written_is 'kb-altcha-key'
expect_five 'altcha-key-2'
printf 'PASS changed key: written alone\n'

if ! play verbose 949b89f 0c856b9 -vvv -e 'web_altcha_hmac_key=altcha-key-3'; then tail -45 "$last_log"; fail '-vvv run failed'; fi
no_copies "$last_log" 'Rp4ss-w0rd.x' 'altcha-key-3' 'smtp p@ss'
expect_secret kb-altcha-key 'altcha-key-3'
printf 'PASS -vvv: no secret value in the log\n'

pem_hash=$(sha "$certs/origin.pem")
key_hash=$(sha "$certs/origin.key")
if ! play new-pair-check 949b89f 0c856b9 --check --diff -e "@$work/inputs-b.json"; then
  tail -45 "$last_log"
  fail 'new pair check failed'
fi
changed_task "$last_log" 'Write the origin certificate and key'
no_copies "$last_log" "$key_b_line" "$key_a_line"
test "$(sha "$certs/origin.pem")" = "$pem_hash" || fail 'new pair check wrote the certificate'
test "$(sha "$certs/origin.key")" = "$key_hash" || fail 'new pair check wrote the key'
printf 'PASS new pair in check mode with --diff: predicted, no key in the log\n'

if play mixed-pair 949b89f 0c856b9 -e "@$work/inputs-mixed.json"; then fail 'mismatched pair was accepted'; fi
grep -F "web: web_origin_key doesn't belong to web_origin_certificate; nothing was written" "$last_log" >/dev/null || fail 'mismatched pair message differs'
no_copies "$last_log" "$key_b_line"
test "$(sha "$certs/origin.pem")" = "$pem_hash" || fail 'mismatched pair wrote the certificate'
test "$(sha "$certs/origin.key")" = "$key_hash" || fail 'mismatched pair wrote the key'
printf 'PASS mismatched pair: refused, both files unchanged\n'

if ! play empty-services 949b89f 0c856b9 -e '{"web_firewall_services": []}'; then tail -45 "$last_log"; fail 'empty service list run failed'; fi
for service in http https; do
  service_open "$service" || fail "empty list closed $service at runtime"
  service_open "$service" --permanent || fail "empty list closed $service permanently"
done
printf 'PASS empty service list: nothing closed\n'

key_file_hash=$(sha "$key_file")
if ! play empty-key 949b89f 0c856b9 -e 'web_deploy_key='; then tail -45 "$last_log"; fail 'empty deploy key run failed'; fi
test "$(sha "$key_file")" = "$key_file_hash" || fail 'empty deploy key changed the key file'
rm -f -- "$key_file"
if ! play empty-key-absent 949b89f 0c856b9 -e 'web_deploy_key='; then tail -45 "$last_log"; fail 'empty deploy key run without a key file failed'; fi
test ! -e "$key_file" || fail 'empty deploy key wrote the key file'
if ! play deploy-key-again 949b89f 0c856b9; then tail -45 "$last_log"; fail 'deploy key run failed'; fi
cmp -s "$key_file" "$work/deploy-key.line" || fail 'deploy key was not written again'
printf 'PASS empty deploy key: none written, none removed\n'

as_user podman network rm keepbreath-net >"$work/network-rm.log"
as_user podman network create --subnet 10.90.0.0/24 keepbreath-net >"$work/network-wrong.log"
if play wrong-network 949b89f 0c856b9; then fail 'mismatched network was accepted'; fi
grep -F 'web: keepbreath-net exists with other settings; the role never changes an existing network, so fix it by hand (Ansible configuration management decision 61.4)' "$last_log" >/dev/null || fail 'mismatched network message differs'
as_user podman network inspect keepbreath-net >"$work/network-wrong.json"
python3 - "$work/network-wrong.json" <<'PY' || fail 'mismatched network changed'
import json, sys
assert json.load(open(sys.argv[1]))[0]['subnets'][0]['subnet'] == '10.90.0.0/24'
PY
printf 'PASS mismatched network: refused unchanged\n'

as_user podman network rm keepbreath-net >"$work/network-rm.log"
as_user podman network create --subnet 10.89.0.0/24 --gateway 10.89.0.1 keepbreath-net >"$work/network-create.log"
network_file="$home/.local/share/containers/storage/networks/keepbreath-net.json"
printf '{broken' >"$network_file"
if play corrupt-network 949b89f 0c856b9; then fail 'corrupt network was accepted'; fi
grep -F "web: podman network inspect keepbreath-net failed in a way that isn't 'network not found'" "$last_log" >/dev/null || fail 'corrupt network message differs'
test "$(cat "$network_file")" = '{broken' || fail 'corrupt network was overwritten'
printf 'PASS corrupt network: refused unchanged\n'

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
  -e 'web_contact_api_ref=0c856b9' -e 'web_smtp_host=mail.keepbreath.ing' \
  -e 'web_smtp_port=2587' -e 'web_smtp_user=contact@keepbreath.ing' \
  -e 'web_smtp_host_address=10.128.0.4' "${secret_inputs[@]}" "${pair_inputs[@]}" >"$work/missing-ref.log" 2>&1; then
  fail 'missing site ref was accepted'
fi
grep -F 'missing required arguments: web_site_ref' "$work/missing-ref.log" >/dev/null || fail 'missing site ref message differs'
printf 'PASS required site ref: argument validation fails\n'

if ansible-playbook -i localhost, tests/web/role.yml -e "web_container_user=$user" \
  -e 'web_site_ref=949b89f' -e 'web_contact_api_ref=0c856b9' \
  -e 'web_smtp_port=2587' -e 'web_smtp_user=contact@keepbreath.ing' \
  -e 'web_smtp_host_address=10.128.0.4' "${secret_inputs[@]}" "${pair_inputs[@]}" >"$work/missing-smtp-host.log" 2>&1; then
  fail 'missing SMTP host was accepted'
fi
grep -F 'missing required arguments: web_smtp_host' "$work/missing-smtp-host.log" >/dev/null || fail 'missing SMTP host message differs'
printf 'PASS required SMTP host: argument validation fails\n'

if ansible-playbook -i localhost, tests/web/role.yml -e "web_container_user=$user" \
  -e 'web_site_ref=949b89f' -e 'web_contact_api_ref=0c856b9' \
  -e 'web_smtp_host=mail.keepbreath.ing' -e 'web_smtp_port=2587' \
  -e 'web_smtp_user=contact@keepbreath.ing' -e 'web_smtp_host_address=10.128.0.4' \
  -e 'web_altcha_hmac_key=altcha-key-1' -e '{"web_smtp_password": "smtp p@ss"}' "${pair_inputs[@]}" \
  >"$work/missing-redis-password.log" 2>&1; then
  fail 'missing Redis password was accepted'
fi
grep -F 'missing required arguments: web_redis_password' "$work/missing-redis-password.log" >/dev/null || fail 'missing Redis password message differs'
no_copies "$work/missing-redis-password.log" 'altcha-key-1' 'smtp p@ss'
printf 'PASS required Redis password: argument validation fails without printing the others\n'

printf 'web driver: all cases passed\n'
