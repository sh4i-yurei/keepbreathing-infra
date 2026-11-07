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
amtool check-config alertmanager.yml

amtool config routes test --config.file=alertmanager.yml \
  --verify.receivers=ntfy-tickets severity=warning
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

echo 'hub rules: all checks passed'
