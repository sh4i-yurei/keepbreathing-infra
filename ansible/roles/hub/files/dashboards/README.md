# Grafana dashboards

The dashboards Grafana on the hub loads at startup (Monitoring and alerting decisions #40, #41 and
#45). Each subfolder becomes a Grafana folder of the same name; `home.json` at the top level is the
page Grafana opens on. Changes made later in Grafana's editor are exported as JSON and committed over
these files.

The upstream dashboards were downloaded from the pinned source below. Each has had exactly two fields
changed: `title`, to say what is on it, and `description`, the line Grafana shows beside it. Nothing
else differs from the source in content; the files were re-serialised, so formatting may differ.
ntfy's dashboard has one further change, noted in its row.

| File | Title | Source, pinned | SHA-256 as downloaded | Licence |
| --- | --- | --- | --- | --- |
| `home.json` | Operations Overview | written for this repo: active alerts and the status of every host, service check and hub container; Grafana opens on it (`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`) | not pinned; edited here | this repository |
| `Infrastructure/node-use-cluster.json` | Fleet Resource Utilization | node_exporter's mixin "Node Exporter / USE Method / Cluster", rendered by monitoring.mixins.dev: `monitoring-mixins/website` commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/node-exporter/dashboards/node-cluster-rsrc-use.json` | `b99e6f23c363ecc6aa890899fbbe449052d940498c905b2a2fa05856b556e648` | Apache-2.0 |
| `Infrastructure/node-exporter-full.json` | Host Detail | "Node Exporter Full", grafana.com dashboard 1860, revision 45 (`rfmoz/grafana-dashboards`) | `184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986` | Apache-2.0 |
| `Services/gatus.json` | Service Availability | "Gatus - Service Monitoring Dashboard", `TwiN/gatus` tag `v5.37.0`, `.examples/docker-compose-grafana-prometheus/grafana/provisioning/dashboards/gatus.json` | `a97a3bddcf6b477d27c639e7921ddeee077718a90c8b491a571245047083ab5a` | Apache-2.0 |
| `Observability Platform/alertmanager-overview.json` | Alerting Pipeline | "Alertmanager / Overview" from Alertmanager's mixin, rendered by monitoring.mixins.dev: commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/alertmanager/dashboards/alertmanager-overview.json` | `da57c5f4edbeceffa6d4bae8a7b46215088482a99aec6dcb3ffb69c6099655fd` | Apache-2.0 |
| `Observability Platform/prometheus-overview.json` | Metrics Pipeline | "Prometheus / Overview" from Prometheus's mixin, rendered by monitoring.mixins.dev: commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/prometheus/dashboards/prometheus.json` | `9cd032ad04ef602be9959d2116596847f8bb0c4c805af03ecde1012fd75c389c` | Apache-2.0 |
| `Observability Platform/ntfy.json` | Notification Delivery | "ntfy App", `binwiederhier/ntfy` tag `v2.29.0`, `examples/grafana-dashboard/ntfy-grafana.json`; every `${DS_PROMETHEUS}` also replaced by `prometheus`, the provisioned data source's uid | `8523abdd3b0362c60b1b5df3bdfcec5f00d69376f87f966844fc20f81d6f9ea8` | Apache-2.0 |

Fleet Resource Utilization reads node-mixin's recording rules, such as
`instance:node_cpu_utilisation:rate5m`, which Prometheus has to be evaluating for its panels to fill.
The upstream dashboards choose their Prometheus data source through a dashboard variable or, for ntfy,
by uid, so none needs further editing before it is provisioned. Service Availability's domain-expiry
panel stays empty, because Gatus does not check domain expiry here.
