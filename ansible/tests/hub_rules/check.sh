#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
role=roles/hub
defaults="$role/defaults/main.yml"
inputs="${HUB_RULES_INPUTS:-}"
runtime_text="${HUB_RULES_RUNTIME:-docker}"
read -r -a runtime <<< "$runtime_text"
test "${#runtime[@]}" -gt 0

prometheus_image=$(awk '$1 == "hub_prometheus_image:" {print $2}' "$defaults")
alertmanager_image=$(awk '$1 == "hub_alertmanager_image:" {print $2}' "$defaults")
test -n "$prometheus_image"
test -n "$alertmanager_image"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
chmod 0755 "$scratch"

rules=(prometheus-rules.yml node-mixin-rules.yml node-mixin-alerts.yml
       prometheus-mixin-alerts.yml alertmanager-mixin-alerts.yml)
for file in "${rules[@]}" prometheus-rules-test.yml; do
  cp "${inputs:-$role/files}/$file" "$scratch/$file"
done
cp "${inputs:-$role/templates}/container-missing-rules.yml.j2" "$scratch/container-missing-rules.yml.j2"
cp "${inputs:-$role/templates}/alertmanager.yml.j2" "$scratch/alertmanager.yml"
chmod 0644 "$scratch"/*

ansible-playbook -i inventory.ini tests/hub_rules/render.yml \
  -e "hub_rules_output=$scratch/container-missing-rules.yml"

promtool() {
  "${runtime[@]}" run --rm -v "$scratch:/work:ro,Z" -w /work \
    --entrypoint /bin/promtool "$prometheus_image" "$@"
}
amtool() {
  "${runtime[@]}" run --rm -v "$scratch:/work:ro,Z" -w /work \
    --entrypoint /bin/amtool "$alertmanager_image" "$@"
}

for file in prometheus-rules.yml container-missing-rules.yml \
  node-mixin-rules.yml node-mixin-alerts.yml prometheus-mixin-alerts.yml \
  alertmanager-mixin-alerts.yml; do
  promtool check rules "$file"
done
promtool test rules prometheus-rules-test.yml
amtool check-config alertmanager.yml | tee "$scratch/check-config.txt"
# nowhere, ntfy-pages, ntfy-tickets and the ticket receiver (OpenBao on the hub decision 76).
grep -Fxq ' - 4 receivers' "$scratch/check-config.txt" || {
  echo 'ASSERTION FAILED: amtool check-config must find 4 receivers' >&2
  exit 1
}

amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=ticket severity=warning
amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=ntfy-pages severity=page
amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=ntfy-pages severity=critical
amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=nowhere severity=info
amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=nowhere alertname=Anything
amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=ntfy-tickets alertname=OpenBaoUnhealthy severity=warning band_health=true
amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=ntfy-tickets severity=page band_health=true

# These label sets were firing as warnings on the hub on 2026-11-11.
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ticket \
  alertname=NodeRebootRequired instance=web job=node severity=warning
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ticket \
  alertname=NodeSystemdServiceFailed instance=hub job=node \
  name=journal-pull@almaserv.service severity=warning state=failed type=simple
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-tickets \
  alertname=OpenBaoUnhealthy band_health=true certificate_ticket=true group=hub \
  instance=169.254.1.3:8081 job=gatus key=hub_openbao name=openbao severity=warning type=HTTP

# Failed sends to the ticket receiver go to the tickets topic whatever their severity, and failed
# sends to ntfy's own receivers keep their severity routes (OpenBao on the hub decisions 29 and 40).
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-tickets \
  alertname=AlertmanagerClusterFailedToSendAlerts severity=critical receiver_name=ticket
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-tickets \
  alertname=AlertmanagerClusterFailedToSendAlerts severity=warning receiver_name=ticket
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-tickets \
  alertname=AlertmanagerFailedToSendAlerts severity=warning receiver_name=ticket
for receiver in ntfy-pages ntfy-tickets; do
  amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-pages \
    alertname=AlertmanagerClusterFailedToSendAlerts severity=critical "receiver_name=$receiver"
  amtool config routes test --config.file=alertmanager.yml --verify.receivers=ticket \
    alertname=AlertmanagerClusterFailedToSendAlerts severity=warning "receiver_name=$receiver"
  amtool config routes test --config.file=alertmanager.yml --verify.receivers=ticket \
    alertname=AlertmanagerFailedToSendAlerts severity=warning "receiver_name=$receiver"
done
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-tickets \
  alertname=TicketDeliveryDown severity=warning band_health=true

# The digest's failed unit reaches the tickets topic; any other failed unit reaches the ticket
# receiver (OpenBao on the hub decisions 35 and 79).
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ntfy-tickets \
  alertname=NodeSystemdServiceFailed severity=warning name=ticket-digest.service
amtool config routes test --config.file=alertmanager.yml --verify.receivers=ticket \
  alertname=NodeSystemdServiceFailed severity=warning name=sshd.service

echo 'hub rules: all checks passed'
