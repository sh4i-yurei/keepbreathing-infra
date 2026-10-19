# node_exporter

This role installs Prometheus's node_exporter, which reports a machine's CPU, memory, disk and
network numbers for Prometheus to collect. It runs the release binary under systemd as its own
account, not in a container.

It is its own role, not part of `hub`, because every server gets node_exporter the same way: the
hub now, the droplets through their own play, and the other VMs after that (Monitoring and
alerting decisions #12, #23 and #24). One copy of these steps means the servers cannot drift
apart.

## What it does, in order

1. Creates the `node_exporter` system account, with no login shell and no home folder.
2. Downloads the release archive into `/var/cache/node_exporter` and refuses it unless its
   SHA-256 matches `node_exporter_sha256`. The checksum is recorded in this repository when a
   version is chosen, not read from the release at install time, because a checksum fetched from
   the same place as the archive only catches a damaged download (decision #25).
3. Unpacks it and copies the binary to `/usr/local/bin/node_exporter`, owned by root.
4. With a password or HTTPS switched on, makes `/etc/node_exporter` (`0755`, because the certificate
   in it is public) and writes `web.yml` there. With HTTPS, it also installs `python3-cryptography`,
   which `community.crypto` needs on the managed machine, and makes a P-256 key (`0640`) and a
   self-signed certificate naming the listen address as an IP SAN, valid for a year. The
   certificate is remade on any run where fewer than 30 days remain, because `x509_certificate`
   does not look at dates on its own (decisions #26 and #29).
5. Writes `/etc/systemd/system/node_exporter.service`, which runs the binary as `node_exporter`
   with a read-only view of the filesystem, listening on `node_exporter_listen_address`. The unit
   switches on the systemd, processes, tcpstat and interrupts collectors, and enables systemd's
   restart metrics so the mixin's crash-loop alert has `node_systemd_service_restart_total`. It
   adds `--web.config.file` when there is one. It retries every 5 seconds with no start limit, so a
   tailnet listen address that appears after boot is picked up.
6. Reconciles the port's source-address rich rules in firewalld's `public` zone with
   `node_exporter_allowed_sources`, adding current addresses and removing stale ones. It touches only
   IPv4 TCP accept rules on node_exporter's port, read by `filter_plugins/node_exporter_firewall.py`.
7. Starts it and enables it at boot, then checks it: the metrics page answers with the pinned
   version, using the password and checking the certificate when those are on; a request without
   the password gets `401`; plain HTTP is refused; each explicitly enabled collector returns a
   metric, including systemd service restart counts; and the process runs as `node_exporter`.

## Inputs

| Variable | Default | What it is |
| --- | --- | --- |
| `node_exporter_version` | `1.12.1` | The release, without the leading `v` |
| `node_exporter_sha256` | the v1.12.1 linux-amd64 archive's | Its SHA-256, recorded with the version |
| `node_exporter_listen_address` | `127.0.0.1:9100` | Where it listens |
| `node_exporter_basic_auth_hash` | empty | The bcrypt hash of the scrape password for the user `prometheus`; empty turns the password off |
| `node_exporter_basic_auth_password` | empty | The password itself, used only by the checks |
| `node_exporter_tls` | `false` | Serve HTTPS with a self-signed certificate made on the machine |
| `node_exporter_allowed_sources` | empty | Complete set of addresses firewalld lets reach the port; empty removes every managed rule |

To change version, set both the version and its checksum together. On the droplets the password
settings come from `group_vars/droplets.yml`, which reads them from each droplet's own vault item.
