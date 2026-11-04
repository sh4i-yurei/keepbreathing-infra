#!/usr/bin/env bash
set -euo pipefail

work=$(mktemp -d)
point=$work/backup
image=$work/backup.img
device=
uid=
user=bstest
quadlet=/home/$user/.config/containers/systemd/backup-server.container
restic_image=$(python3 -c 'import yaml; print(yaml.safe_load(open("group_vars/all.yml"))["restic_image"])')
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
as_user() {
  (
    cd "$work"
    HOME="/home/$user" USER="$user" LOGNAME="$user" \
      XDG_RUNTIME_DIR="/run/user/$uid" XDG_CONFIG_HOME="/home/$user/.config" \
      runuser -u "$user" -- "$@"
  )
}
cleanup() {
  if [[ -z $uid ]] && id -u "$user" >/dev/null 2>&1; then uid=$(id -u "$user"); fi
  if [[ -n $uid ]]; then
    as_user systemctl --user stop backup-server.service >/dev/null 2>&1 || true
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
    systemctl stop "user@$uid.service" >/dev/null 2>&1 || true
    userdel -r "$user" >/dev/null 2>&1 || true
  fi
  mountpoint -q "$point" && umount "$point"
  [[ -z $device ]] || losetup -d "$device"
  rm -rf "$work"
}
trap cleanup EXIT
# GitHub's image puts the runner's XDG paths in /etc/environment. PAM reads
# them when the new user manager starts. Clear both before bstest exists.
sed -i '/^XDG_CONFIG_HOME=/d; /^XDG_RUNTIME_DIR=/d' /etc/environment
unset XDG_CONFIG_HOME XDG_RUNTIME_DIR
systemctl unset-environment XDG_RUNTIME_DIR
export TEST_MOUNT="$point"
export TEST_RESTIC_IMAGE="$restic_image"
export TEST_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_RESTIC_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export TEST_BCRYPT="$(htpasswd -nbB verify "$TEST_PASSWORD" | cut -d: -f2-)"
export RESTIC_REPOSITORY="rest:http://127.0.0.1:8082/verify/"
export RESTIC_REST_USERNAME=verify
export RESTIC_REST_PASSWORD="$TEST_PASSWORD"
export RESTIC_PASSWORD="$TEST_RESTIC_PASSWORD"

mkdir -p "$point"
chmod 0755 "$work"
truncate -s 512M "$image"
device=$(losetup --find --show "$image")
mkfs.xfs -f -q "$device"
mount "$device" "$point"
play() {
  local name=$1 log=$work/$1.log
  if ! ansible-playbook -i localhost, "tests/backup_server/$name.yml" >"$log" 2>&1; then
    tail -35 "$log"
    if [[ -z $uid ]] && id -u "$user" >/dev/null 2>&1; then uid=$(id -u "$user"); fi
    if [[ -n $uid ]]; then
      as_user systemctl --user status backup-server.service --no-pager | tail -22 || true
      as_user journalctl --user -u backup-server.service -n 30 --no-pager || true
      stat -c 'runtime owner=%u group=%g mode=%a path=%n' "/run/user/$uid" "/run/user/$uid/libpod" 2>&1 || true
      as_user id
      as_user test -w "/run/user/$uid" && echo 'runtime writable by account' || echo 'runtime not writable by account'
      as_user systemctl --user show-environment | grep -E '^(XDG_RUNTIME_DIR|XDG_CONFIG_HOME|HOME|USER)=' || true
    fi
    fail "$name play must pass"
  fi
}
expect_verify_failure() {
  local label=$1 phrase=$2 log=$work/$1.log
  if ansible-playbook -i localhost, tests/backup_server/verify.yml >"$log" 2>&1; then
    fail "$label: verify unexpectedly passed"
  fi
  grep -Fq '"msg": "The '"$phrase" "$log" || { tail -25 "$log"; fail "$label: expected $phrase failure message"; }
  printf 'PASS %s refusal detected\n' "$label"
}
snapshots() {
  as_user podman run --rm --network host --env RESTIC_REPOSITORY --env RESTIC_PASSWORD \
    --env RESTIC_REST_USERNAME --env RESTIC_REST_PASSWORD \
    "$restic_image" snapshots --json
}
snapshot_count() { snapshots | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
reload_service() {
  as_user systemctl --user daemon-reload
  as_user systemctl --user restart backup-server.service
}

if ansible-playbook -i localhost, tests/backup_server/missing-user.yml >"$work/missing.log" 2>&1; then
  fail 'missing backup_server_user must fail argument validation'
fi
grep -Fq 'missing required arguments: backup_server_user' "$work/missing.log" || fail 'missing user must fail at argument validation'
[[ ! -e /home/bstest && ! -e "$point/restic" ]] || fail 'missing user must create no account or data folder'
[[ -z $(find /home -path '*/.config/containers/systemd/backup-server.container' -print -quit) ]] || fail 'missing user must create no Quadlet file'
printf 'PASS required account rejected before changes\n'

if ! ansible-playbook -i localhost, tests/backup_server/server.yml --check --diff >"$work/server-check.log" 2>&1; then
  tail -25 "$work/server-check.log"
  fail 'fresh-account backup_server check mode must pass'
fi
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/server-check.log" || fail 'backup_server check mode must report failed=0'
[[ ! -e /home/bstest && ! -e "$point/restic" ]] || fail 'backup_server check mode must create no account or data folder'
[[ -z $(find /home -path '*/.config/containers/systemd/backup-server.container' -print -quit) ]] || fail 'backup_server check mode must create no Quadlet file'
printf 'PASS fresh-account backup_server check mode\n'

export TEST_SERVICE_NAME=backup TEST_SERVICE_PORT=8082 TEST_STUB_DIR="$work/bin" TEST_STATUS="$work/status.json" TEST_CALLS="$work/calls"
mkdir -p "$work/bin"
cat >"$work/bin/tailscale" <<'SH'
#!/usr/bin/env bash
if [[ $* == 'serve status --json' ]]; then cat "$TEST_STATUS"; exit; fi
printf '%s\n' "$*" >>"$TEST_CALLS"
SH
chmod +x "$work/bin/tailscale"
printf '{"Services":{}}\n' >"$work/status.json"
: >"$TEST_CALLS"
if ! ansible-playbook -i localhost, tests/backup_server/tailscale.yml --check >"$work/tailscale-check.log" 2>&1; then
  tail -25 "$work/tailscale-check.log"
  fail 'tailscale_service check mode must pass'
fi
grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/tailscale-check.log" || fail 'tailscale_service check mode must report failed=0'
[[ ! -s $TEST_CALLS ]] || fail 'tailscale_service check mode must not serve or clear'
printf 'PASS tailscale_service check mode\n'

play server
uid=$(id -u "$user") || fail 'backup_server must create its account'
as_user systemctl --user is-active --quiet backup-server.service || fail 'backup-server.service must be active'
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8082/")
[[ $code == 401 || $code == 403 ]] || fail 'loopback HTTP must answer with authentication required'
[[ $(snapshot_count) == 1 ]] || fail 'first verified run must create one snapshot'
printf 'PASS first role run and one snapshot\n'

play server
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/server.log" || fail 'second run must report changed=0'
[[ $(snapshot_count) == 2 ]] || fail 'second verified run must create a second snapshot'
printf 'PASS second role run changed=0 and two snapshots\n'

cp "$quadlet" "$work/original.container"
before=$(snapshot_count)
sed -i 's/ --append-only//' "$quadlet"
reload_service
expect_verify_failure append-only 'append-only protection failed'
after=$(snapshot_count)
(( after == before )) || fail 'forget must delete its new snapshot with append-only disabled'
cp "$work/original.container" "$quadlet"
reload_service

sed -i 's/ --private-repos//' "$quadlet"
reload_service
expect_verify_failure private-repositories 'private repositories protection failed'
cp "$work/original.container" "$quadlet"
reload_service

sed -i 's@ --htpasswd /etc/rclone/htpasswd --private-repos@@' "$quadlet"
reload_service
expect_verify_failure login 'login check failed'
cp "$work/original.container" "$quadlet"
reload_service

before_snapshots=$(snapshots)
as_user systemctl --user stop backup-server.service
umount "$point"
install -d -o "$user" -g "$user" -m 0700 "$point/restic"
as_user systemctl --user start backup-server.service >/dev/null 2>&1 || true
for ((second=0; second<15; second++)); do
  as_user systemctl --user is-active --quiet backup-server.service && fail 'service became active without the backup mount'
  sleep 1
done
restarts=$(as_user systemctl --user show backup-server.service -p NRestarts --value)
(( restarts >= 2 )) || fail 'service must retry at least twice while mount is absent'
[[ -z $(find "$point/restic" -mindepth 1 -print -quit) ]] || fail 'unmounted restic folder must stay empty'
mount "$device" "$point"
active=false
for ((second=0; second<15; second++)); do
  if as_user systemctl --user is-active --quiet backup-server.service; then active=true; break; fi
  sleep 1
done
[[ $active == true ]] || fail 'service must recover without a manual start after remount'
play verify
after_snapshots=$(snapshots)
python3 - "$before_snapshots" "$after_snapshots" <<'PY' || fail 'remounted repository must retain every old snapshot and add one'
import json
import sys
before = {item['id'] for item in json.loads(sys.argv[1])}
after = {item['id'] for item in json.loads(sys.argv[2])}
assert before < after
PY
printf 'PASS mount loss, retries, automatic recovery and preserved snapshots\n'

cat >"$work/status.json" <<'JSON'
{
  "Services": {
    "svc:grafana": {
      "TCP": {
        "443": {
          "HTTPS": true
        }
      },
      "Web": {
        "grafana.tail4cf2f3.ts.net:443": {
          "Handlers": {
            "/": {
              "Proxy": "http://127.0.0.1:3000"
            }
          }
        }
      }
    },
    "svc:ntfy": {
      "TCP": {
        "443": {
          "HTTPS": true
        }
      },
      "Web": {
        "ntfy.tail4cf2f3.ts.net:443": {
          "Handlers": {
            "/": {
              "Proxy": "http://127.0.0.1:8080"
            }
          }
        }
      }
    }
  }
}
JSON
export TEST_STUB_DIR="$work/bin" TEST_STATUS="$work/status.json" TEST_CALLS="$work/calls"
for pair in grafana:3000 backup:8082 ntfy:8090; do
  export TEST_SERVICE_NAME=${pair%%:*} TEST_SERVICE_PORT=${pair##*:}
  : >"$TEST_CALLS"
  play tailscale
  case $TEST_SERVICE_NAME in
    grafana)
      [[ ! -s $TEST_CALLS ]] || fail 'unchanged Grafana Service must make no calls'
      grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/tailscale.log" || fail 'unchanged Grafana Service must report changed=0';;
    *)
      expected=$(printf 'serve clear svc:%s\nserve --yes --service=svc:%s --https=443 127.0.0.1:%s' \
        "$TEST_SERVICE_NAME" "$TEST_SERVICE_NAME" "$TEST_SERVICE_PORT")
      [[ $(cat "$TEST_CALLS") == "$expected" ]] || fail "$TEST_SERVICE_NAME must clear then serve only itself";;
  esac
  printf 'PASS tailscale_service %s\n' "$TEST_SERVICE_NAME"
done
