#!/usr/bin/env bash
set -euo pipefail

work=$(mktemp -d)
point=$work/backup
device=
bs_uid=
vw_uid=
image=docker.io/vaultwarden/server@sha256:5d326778c22f063d093d6b0c9c766a28249561632266776f2c93132ab0ad3a80
restic_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image"])')
run_unit=/home/vwtest/.config/systemd/user/vaultwarden-backup-run.service
env_file=/home/vwtest/.config/vaultwarden-backup/restic.env
quadlet=/home/vwtest/.config/containers/systemd/vaultwarden.container
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
as_user() {
  local name=$1 uid=$2
  shift 2
  (cd "$work" && HOME="/home/$name" USER="$name" LOGNAME="$name" \
    XDG_RUNTIME_DIR="/run/user/$uid" XDG_CONFIG_HOME="/home/$name/.config" \
    runuser -u "$name" -- "$@")
}
as_bs() { as_user bstest "$bs_uid" "$@"; }
as_vw() { as_user vwtest "$vw_uid" "$@"; }
cleanup() {
  if [[ -n ${listener:-} ]]; then kill "$listener" >/dev/null 2>&1 || true; fi
  if [[ -n $vw_uid ]]; then
    as_vw systemctl --user stop vaultwarden.service >/dev/null 2>&1 || true
    loginctl disable-linger vwtest >/dev/null 2>&1 || true
    systemctl stop "user@$vw_uid.service" >/dev/null 2>&1 || true
    userdel -r vwtest >/dev/null 2>&1 || true
  fi
  if [[ -z $bs_uid ]] && id -u bstest >/dev/null 2>&1; then bs_uid=$(id -u bstest); fi
  if [[ -n $bs_uid ]]; then
    as_bs systemctl --user stop backup-server.service >/dev/null 2>&1 || true
    loginctl disable-linger bstest >/dev/null 2>&1 || true
    systemctl stop "user@$bs_uid.service" >/dev/null 2>&1 || true
    userdel -r bstest >/dev/null 2>&1 || true
  fi
  mountpoint -q "$point" && umount "$point"
  [[ -z $device ]] || losetup -d "$device"
  rm -rf "$work"
}
trap cleanup EXIT

# GitHub's image leaks the runner's XDG paths through PAM into fresh user managers.
sed -i '/^XDG_CONFIG_HOME=/d; /^XDG_RUNTIME_DIR=/d' /etc/environment
unset XDG_CONFIG_HOME XDG_RUNTIME_DIR
systemctl unset-environment XDG_RUNTIME_DIR

export TEST_MOUNT="$point" TEST_DATA="$work/data"
export TEST_RESTIC_IMAGE="$restic_image"
export TEST_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_RESTIC_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_VERIFY_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_VERIFY_RESTIC_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_VAULT_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_VAULT_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_EMAIL="backup-$(python3 -c 'import secrets; print(secrets.token_hex(6))')@example.test"
export TEST_BCRYPT="$(htpasswd -nbB vwbackup "$TEST_PASSWORD" | cut -d: -f2-)"
export TEST_VERIFY_BCRYPT="$(htpasswd -nbB verify "$TEST_VERIFY_PASSWORD" | cut -d: -f2-)"

mkdir -p "$point" "$TEST_DATA"
chmod 0755 "$work"
truncate -s 512M "$work/backup.img"
device=$(losetup --find --show "$work/backup.img")
mkfs.xfs -f -q "$device"
mount "$device" "$point"

if ansible-playbook -i localhost, tests/vaultwarden_backup/missing-repository.yml >"$work/missing.log" 2>&1; then
  fail 'missing repository must fail argument validation'
fi
grep -Fq "missing required arguments: vaultwarden_backup_repository" "$work/missing.log" || fail 'missing repository must fail at argument validation'
grep -Fq "Validating arguments against arg spec 'main'" "$work/missing.log" || fail 'argument validation task name must be shown'
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'missing repository must create no role files'
printf 'PASS missing repository rejected before changes\n'

if ! ansible-playbook -i localhost, tests/vaultwarden_backup/backup-server.yml >"$work/server.log" 2>&1; then
  tail -30 "$work/server.log"
  fail 'backup server role must pass'
fi
bs_uid=$(id -u bstest)
useradd -m vwtest
vw_uid=$(id -u vwtest)
loginctl enable-linger vwtest
systemctl start "user@$vw_uid.service"
install -d -o vwtest -g vwtest -m 0700 /home/vwtest/.config/containers/systemd
chown vwtest:vwtest "$TEST_DATA"
cat >"$quadlet" <<EOF
[Unit]
Description=Test Vaultwarden
[Container]
ContainerName=vaultwarden
Image=$image
PublishPort=127.0.0.1:8080:80
Volume=$TEST_DATA:/data:Z
Environment=SIGNUPS_ALLOWED=true
[Install]
WantedBy=default.target
EOF
chown vwtest:vwtest "$quadlet"
as_vw systemctl --user daemon-reload
as_vw systemctl --user start vaultwarden.service
ready=false
for ((attempt=0; attempt<40; attempt++)); do
  if [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/alive) == 200 ]]; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]] || fail 'Vaultwarden must become healthy'
python3 tests/vaultwarden_backup/api.py seed || fail 'API must create one user, two items and one attachment'
printf 'PASS Vaultwarden API seed\n'

loginctl disable-linger vwtest
if ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml >"$work/linger.log" 2>&1; then fail 'role must require baseline lingering'; fi
grep -Fq 'lingering' "$work/linger.log" || fail 'lingering failure must name lingering'
grep -Fq 'baseline' "$work/linger.log" || fail 'lingering failure must name baseline role'
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'missing lingering must create no role files'
[[ ! -e /var/lib/systemd/linger/vwtest ]] || fail 'role must not enable lingering'
loginctl enable-linger vwtest
systemctl start "user@$vw_uid.service"
as_vw systemctl --user start vaultwarden.service
printf 'PASS role requires baseline lingering before changes\n'

if ! ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml --check --diff >"$work/check.log" 2>&1; then
  tail -30 "$work/check.log"
  fail 'fresh Vaultwarden backup check mode must pass'
fi
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/check.log" || fail 'check mode recap must report failed=0'
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'check mode must leave no role files'
[[ ! -e $point/restic/vwbackup/config ]] || fail 'check mode must leave no repository snapshot'
printf 'PASS fresh check mode leaves no state\n'

play() {
  local log=$1
  shift
  if ! ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml "$@" >"$log" 2>&1; then
    tail -35 "$log"
    fail 'Vaultwarden backup role play must pass'
  fi
  grep -Eq 'localhost[[:space:]]+:.*failed=0' "$log" || fail 'Vaultwarden backup play recap must report failed=0'
}
restic() {
  as_vw podman run --rm --network host --security-opt label=disable \
    --env-file "$env_file" --volume "$work:$work:rw" "$restic_image" "$@"
}
install -d -o vwtest -g vwtest -m 0755 /home/vwtest/.local
chmod 0755 /home/vwtest/.config
snapshot_count() { restic snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
assert_no_restore_state() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/alive) == 000 ]] || fail 'restore port 8090 must be closed'
  [[ -z $(as_vw podman ps --filter name=vaultwarden-backup-restore --format '{{.Names}}') ]] || fail 'throwaway restore container must be removed'
  [[ -z $(find /tmp -maxdepth 1 -name 'vaultwarden-restore-*' -print -quit) ]] || fail 'restore folder must be removed'
}

play "$work/first.log"
[[ $(stat -c '%a:%U' /home/vwtest/.config) == 755:vwtest ]] || fail 'role must preserve .config mode and owner'
[[ $(stat -c '%a:%U' /home/vwtest/.local) == 755:vwtest ]] || fail 'role must preserve .local mode and owner'
[[ $(systemctl show vaultwarden-backup.timer -p UnitFileState --value) == enabled ]] || fail 'backup timer must be enabled'
[[ $(systemctl show vaultwarden-backup.timer -p ActiveState --value) == active ]] || fail 'backup timer must be active'
[[ $(systemctl show vaultwarden-backup.timer -p Persistent --value) == yes ]] || fail 'backup timer must be persistent'
[[ $(snapshot_count) == 1 ]] || fail 'first verified role run must create exactly one snapshot'
assert_no_restore_state
[[ $(stat -c '%a:%U' "$env_file") == 600:vwtest ]] || fail 'restic environment file must be private to vwtest'
for file in "$work/first.log" "$run_unit" /etc/systemd/system/vaultwarden-backup.timer /etc/systemd/system/vaultwarden-backup.service; do
  ! grep -Fq "$TEST_PASSWORD" "$file" || fail "login password leaked into $file"
  ! grep -Fq "$TEST_RESTIC_PASSWORD" "$file" || fail "restic password leaked into $file"
done
printf 'PASS first role run, private credentials, timer and cleanup\n'

restic ls latest --json >"$work/ls.json"
python3 - "$work/ls.json" <<'PY' || fail 'first snapshot must hold exactly the consistent copy, key, attachment and Quadlet'
import json, re, sys
records = [json.loads(line) for line in open(sys.argv[1])]
entries = [record for record in records if 'path' in record]
paths = [entry['path'] for entry in entries]
files = [entry['path'] for entry in entries if entry.get('type') == 'file']
assert len([p for p in files if re.search(r'/db_\d{8}_\d{6}\.sqlite3$', p)]) == 1, files
assert any(p.endswith('/rsa_key.pem') for p in files), files
assert any('/attachments/' in p for p in files), files
assert any(p.endswith('/vaultwarden.container') for p in files), files
assert not any(p.endswith(('/db.sqlite3', '/db.sqlite3-wal', '/db.sqlite3-shm')) or any(p == f'/backup/data/{name}' or p.startswith(f'/backup/data/{name}/') for name in ('icon_cache', 'tmp')) for p in paths), paths
PY
[[ -z $(find "$TEST_DATA" -maxdepth 1 -name 'db_*.sqlite3' -print -quit) ]] || fail 'successful backup must delete the database copy'
printf 'PASS first snapshot contents and database copy cleanup\n'

install -d -o vwtest -g vwtest "$work/old"
restic restore latest --exclude-xattr '*' --target "$work/old" >/dev/null
old_copy=$(find "$work/old/backup/data" -maxdepth 1 -name 'db_*.sqlite3' -print -quit)
[[ -n $old_copy ]] || fail 'first snapshot must restore a database copy'
play "$work/second.log"
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/second.log" || fail 'second role run must report changed=0'
[[ $(snapshot_count) == 2 ]] || fail 'second verified role run must create two snapshots'
printf 'PASS second role run changed=0 and two snapshots\n'

python3 tests/vaultwarden_backup/api.py third || fail 'API must create third item'
systemctl start vaultwarden-backup.service || fail 'system service must succeed after third item'
[[ $(systemctl show vaultwarden-backup.service -p Result --value) == success ]] || fail 'system service must end with Result=success'
install -d -o vwtest -g vwtest "$work/third"
restic restore latest --exclude-xattr '*' --target "$work/third" >/dev/null
new_copy=$(find "$work/third/backup/data" -maxdepth 1 -name 'db_*.sqlite3' -print -quit)
python3 - "$new_copy" <<'PY' || fail 'newest restored copy must contain three ciphers'
import sqlite3, sys
db = sqlite3.connect(f'file:{sys.argv[1]}?mode=ro', uri=True)
assert db.execute('select count(*) from ciphers').fetchone()[0] == 3
PY
printf 'PASS direct system service run captures third item\n'

before=$(snapshot_count)
as_bs systemctl --user stop backup-server.service
if systemctl start vaultwarden-backup.service; then fail 'system service must fail when backup server is stopped'; fi
[[ $(systemctl is-failed vaultwarden-backup.service) == failed ]] || fail 'system service must report failed when backup server is stopped'
[[ -z $(find "$TEST_DATA" -maxdepth 1 -name 'db_*.sqlite3' -print -quit) ]] || fail 'failed restic run must delete database copy'
as_bs systemctl --user start backup-server.service
[[ $(snapshot_count) == "$before" ]] || fail 'backup server outage must create no snapshot'
printf 'PASS backup server outage propagates failure and cleans copy\n'

as_vw systemctl --user stop vaultwarden.service
if systemctl start vaultwarden-backup.service; then fail 'system service must fail when Vaultwarden is stopped'; fi
[[ $(systemctl is-failed vaultwarden-backup.service) == failed ]] || fail 'system service must report failed when Vaultwarden is stopped'
[[ $(snapshot_count) == "$before" ]] || fail 'Vaultwarden outage must create no snapshot'
as_vw systemctl --user start vaultwarden.service
printf 'PASS Vaultwarden outage propagates failure\n'

as_vw cp "$old_copy" "$TEST_DATA/db_20200101_000000.sqlite3"
systemctl start vaultwarden-backup.service || fail 'system service must succeed after stale copy'
[[ ! -e $TEST_DATA/db_20200101_000000.sqlite3 ]] || fail 'stale database copy must be removed'
restic ls latest --json >"$work/stale-ls.json"
python3 - "$work/stale-ls.json" <<'PY' || fail 'new snapshot must contain only the fresh database copy'
import json, re, sys
paths = [json.loads(line)['path'] for line in open(sys.argv[1]) if json.loads(line).get('type') == 'file']
copies = [p for p in paths if re.search(r'/db_.*\.sqlite3$', p)]
assert len(copies) == 1 and not copies[0].endswith('/db_20200101_000000.sqlite3'), copies
PY
printf 'PASS stale database copy removed before backup\n'

cp "$run_unit" "$work/original-run.service"
sed -i 's@--exclude=/backup/data/tmp@--exclude=/backup/data/tmp --exclude=/backup/data/attachments@' "$run_unit"
as_vw systemctl --user daemon-reload
if ansible-playbook -i localhost, tests/vaultwarden_backup/verify.yml >"$work/attachments.log" 2>&1; then fail 'verify must detect omitted attachments'; fi
grep -Fq 'attachments and files check failed' "$work/attachments.log" || { tail -25 "$work/attachments.log"; fail 'verify must name attachments and files check'; }
cp "$work/original-run.service" "$run_unit"
as_vw systemctl --user daemon-reload
printf 'PASS verify detects missing attachments\n'

sed -i "s@/usr/bin/podman exec vaultwarden /vaultwarden backup@/usr/bin/cp $old_copy $TEST_DATA/db_20200101_000001.sqlite3@" "$run_unit"
as_vw systemctl --user daemon-reload
if ansible-playbook -i localhost, tests/vaultwarden_backup/verify.yml >"$work/counts.log" 2>&1; then fail 'verify must detect stale database counts'; fi
grep -Fq 'counts check failed' "$work/counts.log" || { tail -25 "$work/counts.log"; fail 'verify must name counts check'; }
cp "$work/original-run.service" "$run_unit"
as_vw systemctl --user daemon-reload
printf 'PASS verify detects stale database counts\n'

before_wrong_password=$(snapshot_count)
correct_restic_password=$TEST_RESTIC_PASSWORD
export TEST_RESTIC_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
if ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml >"$work/wrong-password.log" 2>&1; then fail 'wrong restic password must fail the play'; fi
grep -Fq 'wrong password' "$work/wrong-password.log" || { tail -25 "$work/wrong-password.log"; fail 'wrong password error must be shown'; }
! grep -Fq 'repository master key and config already initialized' "$work/wrong-password.log" || fail 'wrong password must not attempt init'
export TEST_RESTIC_PASSWORD=$correct_restic_password
play "$work/right-password.log"
[[ $(snapshot_count) == $((before_wrong_password + 1)) ]] || fail 'correct password must preserve existing snapshots'
printf 'PASS wrong restic password reports probe error without init\n'

play "$work/timeout-setup.log" -e vaultwarden_backup_timeout=60
as_bs systemctl --user stop backup-server.service
python3 - "$work/listener-ready" <<'PY' &
import pathlib, socket, sys, time
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 8082))
server.listen()
pathlib.Path(sys.argv[1]).touch()
while True:
    connection, _ = server.accept()
    time.sleep(120)
    connection.close()
PY
listener=$!
for ((attempt=0; attempt<40; attempt++)); do [[ -e $work/listener-ready ]] && break; sleep 0.25; done
[[ -e $work/listener-ready ]] || fail 'hanging listener must start'
if systemctl start vaultwarden-backup.service; then fail 'hanging restic run must time out'; fi
[[ $(as_vw systemctl --user show vaultwarden-backup-run.service -p Result --value) == timeout ]] || fail 'run unit must report timeout'
[[ $(systemctl show vaultwarden-backup.service -p Result --value) == exit-code ]] || fail 'system service must report run unit failure'
[[ $(systemctl is-failed vaultwarden-backup.service) == failed ]] || fail 'system service must be failed after timeout'
[[ -z $(find "$TEST_DATA" -maxdepth 1 -name 'db_*.sqlite3' -print -quit) ]] || fail 'timeout must delete database copy'
kill "$listener"
wait "$listener" || true
listener=
as_bs systemctl --user start backup-server.service
printf 'PASS hanging restic run times out in user unit and cleans copy\n'

printf 'PASS all Vaultwarden backup role cases\n'
