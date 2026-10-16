# hub

This role runs the hub's rootless Quadlet services under `hub_container_user`: ntfy, Gatus,
Alertmanager, the Podman exporter, Prometheus and Grafana. It also keeps the hub's own subnet ahead
of accepted tailnet routes and publishes ntfy and Grafana as Tailscale Services.

## Prometheus

Prometheus scrapes itself, node_exporter on the hub and the other monitored machines, Gatus,
Alertmanager, ntfy, the Podman exporter and Grafana. Alertmanager and Grafana each use a separate
basic-auth password from Vaultwarden. The role writes only those passwords to `0600` files under
Prometheus's configuration folder; `prometheus.yml` contains the usernames and file paths.

The five alerting-rule files contain 62 alerting rules. A sixth file contains node_exporter's
recording rules. The `ContainerMissing` rule is rendered separately from
`container-missing-rules.yml.j2`. Its list of expected containers comes from the base names of every
`templates/*.container.j2` file, so adding or removing a Quadlet template changes the alert without
a second hand-written list. It waits five minutes before paging and stays quiet when the Podman
exporter is not up, leaving that failure to `TargetDown`.

## Grafana metrics

Grafana serves `/metrics` on its web port. The `[metrics]` username is `prometheus`; its password
comes from the Login item `grafana prometheus (hub)` and reaches Grafana through
`GF_METRICS_BASIC_AUTH_PASSWORD__FILE`. The secret file has the same `0600` mode and ownership as
Grafana's admin-password file. The verify tasks require an anonymous metrics request to return
`401` and the vault password to return `200`.
