# Grafana dashboards

The dashboards Grafana on the hub loads at startup (Monitoring and alerting decisions #40 and #41).
Each file is a copy of a published dashboard, downloaded from the pinned source below and committed
unchanged, so the repo shows exactly what Grafana loads. Changes made later in Grafana's editor are
exported as JSON and committed over these files.

| File | Dashboard | Source, pinned | SHA-256 as downloaded | Licence |
| --- | --- | --- | --- | --- |
| `node-use-cluster.json` | Node Exporter / USE Method / Cluster | node_exporter's mixin, rendered by monitoring.mixins.dev: `monitoring-mixins/website` commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/node-exporter/dashboards/node-cluster-rsrc-use.json` | `b99e6f23c363ecc6aa890899fbbe449052d940498c905b2a2fa05856b556e648` | Apache-2.0 |
| `node-exporter-full.json` | Node Exporter Full | grafana.com dashboard 1860, revision 45 (`rfmoz/grafana-dashboards`) | `184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986` | Apache-2.0 |
| `home.json` | Hub | written for this repo: alerts firing or pending, every dashboard, and each machine's and uptime check's state. Grafana opens on it (`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`) | not pinned; edited here | this repository |
| `prometheus-overview.json` | Prometheus / Overview | Prometheus's mixin, rendered by monitoring.mixins.dev: commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/prometheus/dashboards/prometheus.json` | `9cd032ad04ef602be9959d2116596847f8bb0c4c805af03ecde1012fd75c389c` | Apache-2.0 |
| `alertmanager-overview.json` | Alertmanager / Overview | Alertmanager's mixin, rendered by monitoring.mixins.dev: commit `8607c0eb5d9de22d796dd092ee4c9348eec3d6bb`, `assets/alertmanager/dashboards/alertmanager-overview.json` | `da57c5f4edbeceffa6d4bae8a7b46215088482a99aec6dcb3ffb69c6099655fd` | Apache-2.0 |
| `ntfy.json` | ntfy App | `binwiederhier/ntfy` tag `v2.29.0`, `examples/grafana-dashboard/ntfy-grafana.json`, with every `${DS_PROMETHEUS}` replaced by `prometheus`, the provisioned data source's uid | `8523abdd3b0362c60b1b5df3bdfcec5f00d69376f87f966844fc20f81d6f9ea8` before that change | Apache-2.0 |
| `gatus.json` | Gatus - Service Monitoring Dashboard | `TwiN/gatus` tag `v5.37.0`, `.examples/docker-compose-grafana-prometheus/grafana/provisioning/dashboards/gatus.json` | `a97a3bddcf6b477d27c639e7921ddeee077718a90c8b491a571245047083ab5a` | Apache-2.0 |

`node-use-cluster.json` reads node-mixin's recording rules, such as
`instance:node_cpu_utilisation:rate`, which Prometheus has to be evaluating for its panels to fill.
All three choose their Prometheus data source through a dashboard variable, so none needs editing
before it is provisioned. The Gatus dashboard's domain-expiry panel stays empty, because Gatus does
not check domain expiry here.
