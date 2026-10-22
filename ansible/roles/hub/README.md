# hub

This role runs the hub's rootless Quadlet services under `hub_container_user`: ntfy, Gatus,
Alertmanager, the Podman exporter, Prometheus and Grafana. It also keeps the hub's own subnet ahead
of accepted tailnet routes and publishes ntfy and Grafana as Tailscale Services.

## Prometheus

Prometheus scrapes itself, node_exporter on the hub and the other monitored machines, Gatus,
Alertmanager, ntfy, every deployed Podman exporter and Grafana. Remote Podman exporters use a
separate per-host basic-auth password; the droplets also use their own self-signed certificates.
The role writes only passwords to `0600` files under Prometheus's configuration folder;
`prometheus.yml` contains the usernames and file paths.

The five alerting-rule files contain 62 alerting rules. A sixth file contains node_exporter's
recording rules. The `ContainerMissing` rule is rendered separately from
`container-missing-rules.yml.j2`. Its list of expected containers comes from the base names of every
`templates/*.container.j2` file. Remote lists live with their machines in `host_vars`. It waits five
minutes before paging and stays quiet when that machine's Podman exporter is not up, leaving that
failure to `TargetDown`.

## Grafana metrics

Grafana serves `/metrics` on its web port. The `[metrics]` username is `prometheus`; its password
comes from the Login item `grafana prometheus (hub)` and reaches Grafana through
`GF_METRICS_BASIC_AUTH_PASSWORD__FILE`. The secret file has the same `0600` mode and ownership as
Grafana's admin-password file. The verify tasks require an anonymous metrics request to return
`401` and the vault password to return `200`.

## Journals, Loki and Alloy

The hub creates its client certificate under `/etc/journal_pull`; the private
key stays there. The gateway play publishes each source's exact server
certificate to `/etc/journal_pull/servers`. The hub play requires all five
server certificates before starting the pullers, including the certificate
installed by hand for `almaserv` as described in
`../journal_gateway/README.md`.

Each `journal-pull@<host>.service` runs the Python wrapper. It reads the last
committed `REMOTE_SOURCE_CURSOR` from that host's imported journal, confirms
that source cursor still exists, then streams new entries into its child
`systemd-journal-remote`. It drops a leading entry when the source sends that
same cursor again. On a first run, it imports all entries still at the source.
If the saved cursor has rotated away, it resumes at the source's oldest entry,
imports a `journal-pull` gap marker before that entry, and increments that
host's persistent `journal_pull_gaps_total` counter. The marker uses a timestamp
halfway between the last imported and first resumed entry when there is room
between their timestamps; otherwise it uses the first resumed timestamp and
precedes that entry in import order. The journal cursor does not expose an
exact count of missing entries, so the marker says the count is unknown.
The counter lives at `/var/lib/journal_pull/<host>/gaps.prom`. The parent is
traversable, and each host folder belongs to `systemd-journal-remote` with
group `node_exporter` and the setgid bit. The puller can replace its own
counter; node_exporter reads it through a link in its textfile collector.
On upgrade, the role copies any existing counter to the new location without
resetting its value. It pauses that host's puller during the copy so an
increment cannot be lost between the copy and the service restart.

A failed child or unplanned stream end fails the unit. Systemd uses `Restart=on-failure`, `RestartSec=30s`,
`StartLimitIntervalSec=600`, and `StartLimitBurst=5`; repeated failure makes
the unit failed for the existing service-failed alert. Each host has a
separate output journal. Journal remote uses `MaxUse=1G`, `KeepFree=10G`, and
`MaxFileSize=64M`.

The rootless Loki and Alloy Quadlets use pinned image digests. Loki listens
only on hub loopback and retains logs for 2160 hours. Alloy reads the hub's
own journal and the five imported directories, with one `host` label per
reader. The node exporter textfile collector reads an hourly measurement of
Loki's data directory and each puller's persistent gap counter. The Loki size
warning fires above 4 GiB. An increase in a gap counter sends a warning ticket
that explains the recovery and what repeated gaps could mean. The hub verify
checks Loki readiness, effective retention, running images, every puller,
the metrics, and a Loki write and query round trip. Verification writes a
temporary file in each counter folder and reads each counter as
`systemd-journal-remote`, then queries Prometheus for all five hosts' counters.

### Live resume test

The hub play installs `/usr/local/libexec/journal-resume-test`. The source
marker mode can use the same repository script on the source. Do this only
during the authorized live run, after the hub and a gateway are healthy.
Run the source and hub steps concurrently in separate host shells; choose a
fresh run ID and a count such as 24. The source interval should leave enough
time for all three hub stop and start cycles. In the commands below, the
working directory is `/` on the named host.

1. Copy `roles/hub/files/journal-resume-test.py` to
   `/usr/local/libexec/journal-resume-test` on the source. On that **source
   host shell**, run
   `/usr/local/libexec/journal-resume-test source-markers --run-id logs-test-1 --count 24 --interval 5`.
   It writes numbered `logger` entries to the source journal.
2. At the same time on the **hub host shell**, run
   `journal-resume-test hub-cycle --host web --run-id logs-test-1 --count 24`.
   It stops and starts `journal-pull@web.service` at three observed points,
   then waits for all markers to be imported.
3. On the **hub host shell**, run
   `journal-resume-test verify --host web --run-id logs-test-1 --count 24`.
   It requires every numbered marker exactly once in the imported journal
   and Loki. Use the actual source name in `--host`.

The lost-cursor test is deliberately separate because it deletes archived
source journals. On the **hub host shell**, run
`journal-resume-test prepare-loss --host web` to stop the puller. After
confirming the source's archived journals may be removed, on that **source
host shell** run
`/usr/local/libexec/journal-resume-test source-vacuum --confirm-delete-archived-journals`.
On the **hub host shell**, run
`journal-resume-test verify-loss --host web`. It starts the puller and
requires an active unit, a new gap marker in the imported journal and Loki,
and an increased gap counter. This procedure needs a
source whose saved cursor is actually removed by the vacuum; the script
fails if the cursor remains available. Do not run this on an irreplaceable
source journal.
