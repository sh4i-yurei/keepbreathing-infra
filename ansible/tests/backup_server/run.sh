#!/usr/bin/env bash
set -euo pipefail

# Prove the mount dependency required by Backups decision 27 on the CI runner.
# The full role tests will use this same account and mount after this check.
work=$(mktemp -d)
point=$work/backup
user=bstest
uid=
cleanup() {
  if [[ -n $uid ]]; then
    runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user stop backup-server.service >/dev/null 2>&1 || true
  fi
  mountpoint -q "$point" && umount "$point"
  rm -rf "$work"
}
trap cleanup EXIT
fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }

mkdir -p "$point"
mount -t tmpfs -o size=64m tmpfs "$point"
useradd -m "$user"
uid=$(id -u "$user")
loginctl enable-linger "$user"
systemctl start "user@$uid.service"
install -d -o "$user" -g "$user" -m 0700 "$point/restic" \
  "/home/$user/.config/containers/systemd"
cat >"/home/$user/.config/containers/systemd/backup-server.container" <<EOF
[Unit]
RequiresMountsFor=$point

[Container]
Image=docker.io/rclone/rclone@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
Exec=serve restic --addr :8080 /data
PublishPort=127.0.0.1:18082:8080
Volume=$point/restic:/data

[Service]
Restart=no
EOF
chown "$user:$user" "/home/$user/.config/containers/systemd/backup-server.container"
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user \
  set-environment "XDG_CONFIG_HOME=/home/$user/.config"
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user daemon-reload
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user cat backup-server.service >/dev/null || fail 'Quadlet generator must expose backup-server.service'
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user start backup-server.service
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user is-active --quiet backup-server.service || fail 'service must first start with the tmpfs mounted'
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user stop backup-server.service
umount "$point"
install -d -o "$user" -g "$user" -m 0700 "$point/restic"
runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user start backup-server.service >/dev/null 2>&1 || true
if runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" systemctl --user is-active --quiet backup-server.service; then
  fail 'RequiresMountsFor must keep the rootless Quadlet inactive when its system mount is absent'
fi
[[ -z $(find "$point/restic" -mindepth 1 -print -quit) ]] || fail 'unmounted restic folder must stay empty'
printf 'PASS RequiresMountsFor kept the service inactive and the unmounted restic folder empty\n'
