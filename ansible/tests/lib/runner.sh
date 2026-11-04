#!/usr/bin/env bash

runner_undo_account() {
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

runner_save_environment() {
  cp -p -- /etc/environment "$work/environment"
  manager_xdg=$(systemctl show-environment | sed -n '/^XDG_RUNTIME_DIR=/p')
  undo_add 'restore /etc/environment' runner_undo_environment
  undo_add 'restore system manager environment' runner_undo_manager_environment
  sed -i '/^XDG_CONFIG_HOME=/d; /^XDG_RUNTIME_DIR=/d' /etc/environment
  unset XDG_CONFIG_HOME XDG_RUNTIME_DIR
  systemctl unset-environment XDG_RUNTIME_DIR
}

runner_undo_environment() { cp -p -- "$work/environment" /etc/environment; }
runner_undo_manager_environment() {
  if [[ -n $manager_xdg ]]; then
    systemctl set-environment "$manager_xdg"
  else
    systemctl unset-environment XDG_RUNTIME_DIR
  fi
}
