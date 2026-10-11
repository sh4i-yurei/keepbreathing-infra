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
4. Writes `/etc/systemd/system/node_exporter.service`, which runs the binary as `node_exporter`
   with a read-only view of the filesystem, listening on `node_exporter_listen_address`.
5. Starts it and enables it at boot, then checks it: the metrics page answers with the pinned
   version, and the process runs as `node_exporter`.

## Inputs

| Variable | Default | What it is |
|---|---|---|
| `node_exporter_version` | `1.12.1` | The release, without the leading `v` |
| `node_exporter_sha256` | the v1.12.1 linux-amd64 archive's | Its SHA-256, recorded with the version |
| `node_exporter_listen_address` | `127.0.0.1:9100` | Where it listens |

To change version, set both the version and its checksum together.
