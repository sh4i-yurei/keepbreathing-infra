# Grafana dashboards

The dashboards Grafana on the hub loads at startup (Monitoring and alerting decisions #40, #41 and
#45). Each subfolder becomes a Grafana folder of the same name; `home.json` at the top level is the
page Grafana opens on. Changes made later in Grafana's editor are exported as JSON and committed over
these files.

The upstream dashboards were downloaded from the pinned source below. Each has had two fields
changed: `title`, to say what is on it, and `description`, the line Grafana shows beside it. Any
other change is listed in that dashboard's row, and nothing else differs from the source in content.
The files were re-serialised, so formatting may differ.

| File | Title | Source, pinned | SHA-256 as downloaded | Licence |
| --- | --- | --- | --- | --- |
| `home.json` | Operations Overview | written for this repo: active alerts and the status of every host, service check and hub container; Grafana opens on it (`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`) | not pinned; edited here | this repository |
| `Infrastructure/node-use-cluster.json` | Fleet Resource Utilization | node_exporter's mixin "Node Exporter / USE Method / Cluster", rendered by monitoring.mixins.dev: `monitoring-mixins/website` commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/node-exporter/dashboards/node-cluster-rsrc-use.json` | `b99e6f23c363ecc6aa890899fbbe449052d940498c905b2a2fa05856b556e648` | Apache-2.0 |
| `Infrastructure/node-exporter-full.json` | Host Detail | "Node Exporter Full", grafana.com dashboard 1860, revision 45 (`rfmoz/grafana-dashboards`) | `184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986` | Apache-2.0 |
| `Infrastructure/container-resources.json` | Container Resources | "Podman Dashboard EN", grafana.com dashboard 17639, revision 1; `${DS_PROMETHEUS-OULUCLOUD-US}` replaced by the provisioned data source uid `prometheus`; CPU, disk and network counters changed to per-second rates with cores, bytes/s and bits/s units; container legends use names; memory shows usage without the host-sized limit; the overview filters to the selected machine and joins by container name; Disk Percentage uses the root filesystem; all machine selectors use exact matching; the overview's two Chinese legends became English | `e86321979389e04a91e0999dab549d0f64abb1dcf3e89725a3c608423654f748` | not stated on grafana.com |
| `Services/gatus.json` | Service Availability | "Gatus - Service Monitoring Dashboard", `TwiN/gatus` tag `v5.37.0`, `.examples/docker-compose-grafana-prometheus/grafana/provisioning/dashboards/gatus.json` | `a97a3bddcf6b477d27c639e7921ddeee077718a90c8b491a571245047083ab5a` | Apache-2.0 |
| `Observability Platform/alertmanager-overview.json` | Alerting Pipeline | "Alertmanager / Overview" from Alertmanager's mixin, rendered by monitoring.mixins.dev: commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/alertmanager/dashboards/alertmanager-overview.json`; its `integration` variable also changed to list only integrations that have sent a notification, because Alertmanager pre-registers counters for all 18 types and upstream drew an empty panel for each | `da57c5f4edbeceffa6d4bae8a7b46215088482a99aec6dcb3ffb69c6099655fd` | Apache-2.0 |
| `Observability Platform/prometheus-overview.json` | Metrics Pipeline | "Prometheus / Overview" from Prometheus's mixin, rendered by monitoring.mixins.dev: commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/prometheus/dashboards/prometheus.json`; its `cluster` variable also changed to `allValue: ".*"` and hidden, because this Prometheus has no `cluster` label and upstream's `.+` matched nothing | `9cd032ad04ef602be9959d2116596847f8bb0c4c805af03ecde1012fd75c389c` | Apache-2.0 |
| `Observability Platform/ntfy.json` | Notification Delivery | "ntfy App", `binwiederhier/ntfy` tag `v2.29.0`, `examples/grafana-dashboard/ntfy-grafana.json`; every `${DS_PROMETHEUS}` also replaced by `prometheus`, the provisioned data source's uid | `8523abdd3b0362c60b1b5df3bdfcec5f00d69376f87f966844fc20f81d6f9ea8` | Apache-2.0 |
| `Observability Platform/grafana-internals.json` | Grafana | "Grafana Internals", grafana.com dashboard 21891, revision 1; adapted because it was written for Grafana on Kubernetes and older metric names: `kubernetes_pod_name="$pod"` became `job="grafana", instance=~"$instance"`, its menus read `grafana_build_info`, `http_request_total` became `grafana_http_request_duration_seconds_count`, Average Memory Usage plots memory instead of its `rate()`, the Dashboard Get panels became Dashboard Load panels reading the `/api/dashboards/uid/:uid` handler's latency because Grafana 13 no longer exports `grafana_api_dashboard_get_milliseconds`, the two Dashboard Save panels were removed because provisioned dashboards are never saved, `${DS_PROMETHEUS}` became the `prometheus` data source, and its uid was set to `grafana-internals` | `4c0adb839ccc5055ec24476c91d07796df106fb4e22d9874537fb52a98432888` | not stated on grafana.com |

Fleet Resource Utilization reads node-mixin's recording rules, such as
`instance:node_cpu_utilisation:rate5m`, which Prometheus has to be evaluating for its panels to fill.
The upstream dashboards choose their Prometheus data source through a dashboard variable or, for ntfy,
Container Resources and Grafana, by the provisioned uid `prometheus`, so none needs further editing
before it is provisioned. Service Availability's Domain Expiration panel reads
`gatus_results_domain_expiration_seconds`, which Gatus's daily `domain-expiration` check of
`keepbreath.ing` exports.
