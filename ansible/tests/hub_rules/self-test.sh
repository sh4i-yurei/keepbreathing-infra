#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

copy_inputs() {
  local destination="$1"
  mkdir "$destination"
  cp roles/hub/files/{prometheus-rules.yml,prometheus-rules-test.yml,node-mixin-rules.yml,node-mixin-alerts.yml,prometheus-mixin-alerts.yml,alertmanager-mixin-alerts.yml} "$destination/"
  cp roles/hub/templates/{container-missing-rules.yml.j2,alertmanager.yml.j2} "$destination/"
}

expect_failure() {
  local name="$1" expected="$2" additional="${3:-}" output
  if output=$(HUB_RULES_INPUTS="$scratch/$name" bash tests/hub_rules/check.sh 2>&1); then
    echo "ASSERTION FAILED: $name passed with broken input" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "ASSERTION FAILED: $name did not report $expected" >&2
    exit 1
  fi
  if [[ -n "$additional" && "$output" != *"$additional"* ]]; then
    echo "ASSERTION FAILED: $name did not report $additional" >&2
    exit 1
  fi
  echo "$name: failed as expected ($expected)"
}

copy_inputs "$scratch/rule-parse"
sed -i '0,/expr: |/s/expr: |/expr: (/' "$scratch/rule-parse/prometheus-rules.yml"
expect_failure rule-parse 'FAILED:'

copy_inputs "$scratch/rule-test"
sed -i '0,/severity: warning/s/severity: warning/severity: page/' \
  "$scratch/rule-test/prometheus-rules-test.yml"
expect_failure rule-test 'FAILED:' 'alertname: JournalPullGapRecovered'

copy_inputs "$scratch/route"
sed -i 's/receiver: ntfy-tickets/receiver: nowhere/' "$scratch/route/alertmanager.yml.j2"
expect_failure route 'WARNING: Expected receivers did not match resolved receivers.'

# Removes the band_health route from the copy, so severity=page band_health=true pages.
copy_inputs "$scratch/band-health-route"
band_health_config="$scratch/band-health-route/alertmanager.yml.j2"
sed -i '/^    - matchers:$/{N;/band_health="true"/{N;N;d}}' "$band_health_config"
if grep -q '^ *- band_health="true"$' "$band_health_config" \
  || cmp -s "$band_health_config" roles/hub/templates/alertmanager.yml.j2; then
  echo "ASSERTION FAILED: band-health-route did not remove the band_health route" >&2
  exit 1
fi
expect_failure band-health-route 'WARNING: Expected receivers did not match resolved receivers.'

# A warning routed to ntfy must fail the ticket route check.
copy_inputs "$scratch/ticket-route"
sed -i 's/^      receiver: ticket$/      receiver: ntfy-tickets/' \
  "$scratch/ticket-route/alertmanager.yml.j2"
expect_failure ticket-route 'WARNING: Expected receivers did not match resolved receivers.'

copy_inputs "$scratch/config"
cat > "$scratch/config/alertmanager.yml.j2" <<'YAML'
route:
  receiver: missing
receivers:
  - name: nowhere
YAML
expect_failure config 'amtool: error: failed to validate 1 file(s)'

echo 'hub rules self-test: all cases passed'
