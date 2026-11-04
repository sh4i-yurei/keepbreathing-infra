#!/usr/bin/env bash

undo_labels=()
undo_actions=()

undo_add() {
  undo_labels+=("$1")
  undo_actions+=("$2")
}

undo_on_exit() {
  local status=$? result index
  trap - EXIT INT TERM HUP
  set +e
  for ((index=${#undo_actions[@]}-1; index>=0; index--)); do
    ( set -e; "${undo_actions[index]}" )
    result=$?
    if ((result != 0)); then
      printf 'CLEANUP FAILED: %s (exit %s)\n' "${undo_labels[index]}" "$result" >&2
      status=1
    fi
  done
  exit "$status"
}

undo_install() {
  trap undo_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}
