#!/usr/bin/env bash
set -euo pipefail

for account in bstest vwtest; do
  if id -u "$account" >/dev/null 2>&1; then
    printf 'ASSERTION FAILED: %s already exists\n' "$account" >&2
    exit 1
  fi
done
writer=/usr/local/libexec/backup-success
dropins=/etc/systemd/system/vaultwarden-backup.service.d
if [[ -e /etc/systemd/system/vaultwarden-backup.timer || -e /etc/systemd/system/vaultwarden-backup.service || -e $dropins ]]; then
  printf 'ASSERTION FAILED: vaultwarden-backup units already exist\n' >&2
  exit 1
fi
if [[ -e $writer ]]; then
  printf 'ASSERTION FAILED: the backup success writer already exists\n' >&2
  exit 1
fi

work=$(mktemp -d)
point=$work/backup
textfile=$work/textfile
export TEST_TEXTFILE=$textfile
bs_uid=
vw_uid=
manager_xdg=
source tests/lib/undo.sh
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
undo_scratch() { rm -rf --one-file-system -- "$work"; }
undo_environment() { cp -p -- "$work/environment" /etc/environment; }
undo_manager_environment() {
  if [[ -n $manager_xdg ]]; then
    systemctl set-environment "$manager_xdg"
  else
    systemctl unset-environment XDG_RUNTIME_DIR
  fi
}
undo_mount() {
  if mountpoint -q "$point"; then umount "$point"; fi
}
undo_account() {
  local account=$1 uid attempt
  if ! id -u "$account" >/dev/null 2>&1; then return 0; fi
  uid=$(id -u "$account")
  if [[ -e /var/lib/systemd/linger/$account ]]; then loginctl disable-linger "$account"; fi
  systemctl stop "user@$uid.service"
  for ((attempt=0; attempt<40; attempt++)); do
    if ! pgrep -u "$uid" >/dev/null; then break; fi
    pkill -KILL -u "$uid"
    sleep 0.25
  done
  if pgrep -u "$uid" >/dev/null; then
    printf 'Processes remain for %s\n' "$account" >&2
    return 1
  fi
  userdel -r "$account"
}
undo_bstest() { undo_account bstest; }
undo_vwtest() { undo_account vwtest; }
undo_vaultwarden_units() {
  if [[ -e /etc/systemd/system/vaultwarden-backup.timer ]]; then
    systemctl disable --now vaultwarden-backup.timer
  fi
  if [[ -e /etc/systemd/system/vaultwarden-backup.service ]]; then
    systemctl stop vaultwarden-backup.service
    if systemctl is-failed --quiet vaultwarden-backup.service; then
      systemctl reset-failed vaultwarden-backup.service
    fi
  fi
  rm -f /etc/systemd/system/vaultwarden-backup.timer /etc/systemd/system/vaultwarden-backup.service
  rm -rf --one-file-system -- "$dropins"
  systemctl daemon-reload
}
undo_listener() {
  if [[ -n ${listener:-} ]] && kill -0 "$listener" 2>/dev/null; then kill "$listener"; fi
}
undo_writer() { rm -f -- "$writer"; }
task_status() {
  python3 - "$1" "$2" <<'PY2'
import pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
header = re.compile(r'^TASK \[[^\]]*: ' + re.escape(sys.argv[2]) + r'\] \*+$')
starts = [index for index, line in enumerate(lines) if header.match(line)]
assert len(starts) == 1, starts
for line in lines[starts[0] + 1:]:
    match = re.match(r'^(ok|changed|skipping|fatal): \[localhost\]', line)
    if match:
        print(match.group(1))
        break
PY2
}
# The six lines node_exporter's writer records for a stage, target, time and limit.
record_lines() {
  local labels="stage=\"$1\",target=\"$2\""
  printf '%s\n' \
    "# HELP backup_last_success_timestamp_seconds Unix time of the stage's last successful run." \
    '# TYPE backup_last_success_timestamp_seconds gauge' \
    "backup_last_success_timestamp_seconds{$labels} $3" \
    "# HELP backup_max_age_seconds Age after which the stage's last success counts as stale." \
    '# TYPE backup_max_age_seconds gauge' \
    "backup_max_age_seconds{$labels} $4"
}
plant_record() { record_lines "$@" >"$textfile/backup-$1-$2.prom"; }
read_record() { "$writer" --read "$1" "$2"; }
require_record() {
  local stage=$1 target=$2 since=$3 limit=$4 time
  time=$(read_record "$stage" "$target" 2>/dev/null) || fail "$stage $target must have a recorded success"
  [[ $time =~ ^[0-9]+$ ]] && ((time >= since)) || fail "$stage $target's record must be no earlier than $since, got $time"
  cmp -s <(record_lines "$stage" "$target" "$time" "$limit") "$textfile/backup-$stage-$target.prom" ||
    fail "$stage $target's record must be the writer's six lines with limit $limit"
}

undo_install
undo_add 'remove scratch folder' undo_scratch

# GitHub's image leaks the runner's XDG paths through PAM into fresh user managers.
cp -p -- /etc/environment "$work/environment"
undo_add 'restore /etc/environment' undo_environment
manager_xdg=$(systemctl show-environment | sed -n '/^XDG_RUNTIME_DIR=/p')
undo_add 'restore system manager environment' undo_manager_environment
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
# Owned by root with mode 0700, so the test accounts cannot enter it (Backups decision 83).
install -d -o root -g root -m 0700 "$textfile"
truncate -s 512M "$work/backup.img"
mkfs.xfs -f -q "$work/backup.img"
mount -o loop "$work/backup.img" "$point"
undo_add 'unmount backup image' undo_mount

undo_add 'remove bstest account' undo_bstest
if ! ansible-playbook -i localhost, tests/vaultwarden_backup/backup-server.yml >"$work/server.log" 2>&1; then
  tail -30 "$work/server.log"
  fail 'backup server role must pass'
fi
bs_uid=$(id -u bstest)
useradd -m vwtest
undo_add 'remove vwtest account' undo_vwtest
undo_add 'remove Vaultwarden backup system units' undo_vaultwarden_units
vw_uid=$(id -u vwtest)
if ansible-playbook -i localhost, tests/vaultwarden_backup/missing-repository.yml >"$work/missing.log" 2>&1; then
  fail 'missing repository must fail argument validation'
fi
grep -Fq "missing required arguments: vaultwarden_backup_repository" "$work/missing.log" || fail 'missing repository must fail at argument validation'
grep -Fq "Validating arguments against arg spec 'main'" "$work/missing.log" || fail 'argument validation task name must be shown'
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'missing repository must create no role files'
printf 'PASS missing repository rejected before changes\n'

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
grep -Fq '"msg": "Account lingering is required; run the baseline role first."' "$work/linger.log" || fail 'lingering failure must show the exact baseline message'
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'missing lingering must create no role files'
[[ ! -e /var/lib/systemd/linger/vwtest ]] || fail 'role must not enable lingering'
loginctl enable-linger vwtest
systemctl start "user@$vw_uid.service"
as_vw systemctl --user start vaultwarden.service
printf 'PASS role requires baseline lingering before changes\n'

if ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml >"$work/no-writer.log" 2>&1; then fail 'role must require the backup success writer'; fi
grep -Fq "\"msg\": \"The backup success writer $writer is missing; apply node_exporter first.\"" "$work/no-writer.log" ||
  { tail -25 "$work/no-writer.log"; fail 'a missing writer must show the exact node_exporter message'; }
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'a missing writer must create no role files'
printf 'PASS role requires the backup success writer before changes\n'
undo_add 'remove the backup success writer' undo_writer
if ! ansible-playbook -i localhost, tests/vaultwarden_backup/backup-success.yml >"$work/writer.log" 2>&1; then
  tail -30 "$work/writer.log"
  fail 'the backup success writer must install'
fi

if ! ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml --check --diff >"$work/check.log" 2>&1; then
  tail -30 "$work/check.log"
  fail 'fresh Vaultwarden backup check mode must pass'
fi
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/check.log" || fail 'check mode recap must report failed=0'
[[ ! -e $env_file && ! -e $run_unit && ! -e /etc/systemd/system/vaultwarden-backup.timer && ! -e /etc/systemd/system/vaultwarden-backup.service ]] || fail 'check mode must leave no role files'
[[ ! -e $point/restic/vwbackup/config ]] || fail 'check mode must leave no repository snapshot'
grep -Fxq '    "msg": "Would record the install time as the first success of backup localhost"' "$work/check.log" ||
  fail 'fresh check mode must report the first success'
[[ ! -e $textfile/backup-backup-localhost.prom ]] || fail 'check mode recorded a success'
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
install -d -o vwtest -g root -m 0755 /home/vwtest/.config/systemd/user
for folder in /home/vwtest/.config /home/vwtest/.local /home/vwtest/.config/systemd /home/vwtest/.config/systemd/user; do
  chown vwtest "$folder"
  chgrp root "$folder"
  chmod 0755 "$folder"
done
[[ ! -e /home/vwtest/.local/libexec ]] || fail 'libexec must be absent before the first run'
as_vw mkdir -p "$TEST_DATA/icon_cache" "$TEST_DATA/tmp"
as_vw sh -c 'printf cache > "$TEST_DATA/icon_cache/seed"; printf temp > "$TEST_DATA/tmp/seed"'
snapshot_count() { restic snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
assert_no_restore_state() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/alive) == 000 ]] || fail 'restore port 8090 must be closed'
  [[ -z $(as_vw podman ps --filter name=vaultwarden-backup-restore --format '{{.Names}}') ]] || fail 'throwaway restore container must be removed'
  [[ -z $(find /tmp -maxdepth 1 -name 'vaultwarden-restore-*' -print -quit) ]] || fail 'restore folder must be removed'
}

if [[ ${TEST_FAIL_AT_IMAGE_PULL:-} == 1 ]]; then
  export TEST_RESTIC_IMAGE="localhost/vaultwarden-backup-unpullable@sha256:$(printf '0%.0s' {1..64})"
fi
started=$(date +%s)
play "$work/first.log"
require_record backup localhost "$started" 93600
for folder in /home/vwtest/.config /home/vwtest/.local /home/vwtest/.config/systemd /home/vwtest/.config/systemd/user; do
  [[ $(stat -c '%a:%U:%G' "$folder") == 755:vwtest:root ]] || fail "role must preserve shared folder mode, owner and group: $folder"
done
[[ $(stat -c '%a:%U:%G' /home/vwtest/.local/libexec) == 700:vwtest:vwtest ]] || fail 'role must create private libexec folder'
[[ $(stat -c '%a:%U' /home/vwtest/.config/vaultwarden-backup) == 700:vwtest ]] || fail 'role must own its private folder'
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

if ! ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml --check --diff >"$work/check-installed.log" 2>&1; then
  tail -30 "$work/check-installed.log"
  fail 'check mode on an installed role must pass'
fi
grep -Eq 'localhost[[:space:]]+:.*changed=0 .*failed=0' "$work/check-installed.log" || fail 'check mode on an installed role must report changed=0'
! grep -Fq 'Would record ' "$work/check-installed.log" || fail 'check mode on an installed role reported a first success'
printf 'PASS check mode on an installed role reports no change\n'

python3 tests/vaultwarden_backup/api.py third || fail 'API must create third item'
plant_record backup localhost 1 93600
started=$(date +%s)
systemctl start vaultwarden-backup.service || fail 'system service must succeed after third item'
[[ $(systemctl show vaultwarden-backup.service -p Result --value) == success ]] || fail 'system service must end with Result=success'
require_record backup localhost "$started" 93600
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
plant_record backup localhost 1 93600
as_bs systemctl --user stop backup-server.service
if systemctl start vaultwarden-backup.service; then fail 'system service must fail when backup server is stopped'; fi
[[ $(systemctl is-failed vaultwarden-backup.service) == failed ]] || fail 'system service must report failed when backup server is stopped'
[[ $(read_record backup localhost) == 1 ]] || fail 'a failed backup must not record a success'
[[ -z $(find "$TEST_DATA" -maxdepth 1 -name 'db_*.sqlite3' -print -quit) ]] || fail 'failed restic run must delete database copy'
as_bs systemctl --user start backup-server.service
[[ $(snapshot_count) == "$before" ]] || fail 'backup server outage must create no snapshot'
printf 'PASS backup server outage propagates failure and cleans copy\n'

as_vw systemctl --user stop vaultwarden.service
if systemctl start vaultwarden-backup.service; then fail 'system service must fail when Vaultwarden is stopped'; fi
[[ $(systemctl is-failed vaultwarden-backup.service) == failed ]] || fail 'system service must report failed when Vaultwarden is stopped'
[[ $(read_record backup localhost) == 1 ]] || fail 'a failed backup must not record a success'
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

# A wrapper whose ExecStartPost= list is emptied backs up without recording, and verify fails.
mkdir "$dropins"
printf '%s\n' '[Service]' 'ExecStartPost=' >"$dropins/no-success.conf"
systemctl daemon-reload
if ansible-playbook -i localhost, tests/vaultwarden_backup/verify.yml >"$work/no-success.log" 2>&1; then fail 'verify must detect a backup that records no success'; fi
grep -Fq '"msg": "vaultwarden-backup.service ran without recording a new success for backup localhost."' "$work/no-success.log" ||
  { tail -25 "$work/no-success.log"; fail 'verify must name the backup that recorded no success'; }
rm -rf --one-file-system -- "$dropins"
systemctl daemon-reload
printf 'PASS verify detects a backup that records no success\n'

before_wrong_password=$(snapshot_count)
correct_restic_password=$TEST_RESTIC_PASSWORD
export TEST_RESTIC_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
rm -f -- "$textfile/backup-backup-localhost.prom"
started=$(date +%s)
if ansible-playbook -i localhost, tests/vaultwarden_backup/vaultwarden.yml >"$work/wrong-password.log" 2>&1; then fail 'wrong restic password must fail the play'; fi
grep -Fq 'wrong password' "$work/wrong-password.log" || { tail -25 "$work/wrong-password.log"; fail 'wrong password error must be shown'; }
! grep -Fq 'repository master key and config already initialized' "$work/wrong-password.log" || fail 'wrong password must not attempt init'
[[ $(task_status "$work/wrong-password.log" 'Vaultwarden backup verify | Require available or absent repository') == fatal ]] ||
  { tail -25 "$work/wrong-password.log"; fail 'the repository check must be the task reported fatal'; }
require_record backup localhost "$started" 93600
printf 'PASS a play whose backup cannot run still records the install time\n'
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
undo_add 'stop hanging listener' undo_listener
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
