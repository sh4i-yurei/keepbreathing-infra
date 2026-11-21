# Web role

W1 creates the container account in the separate `account` entry point. The main
entry point installs git and clones the site and contact API into account-owned
folders under `/srv` only when they are missing. It leaves existing checkouts at
their current commits. It refuses an occupied path that is not a checkout and
requires the site's container unit to publish its server on loopback.

W2 makes `keepbreath-net` when absent, refuses one with different settings or one
Podman cannot read, and writes the worker's relay drop-in at
`~/.config/containers/systemd/contact-worker.container.d/50-relay.conf`. It
leaves every other drop-in alone and registers `web_relay_dropin` for W5. A check
run predicts missing clones and network creation without making them.

W3 writes the account's five Podman secrets: `kb-redis-conf`, `kb-rediscli-auth`,
`kb-broker-url`, `kb-altcha-key` and `kb-smtp-pass`. It compares each stored
secret with its wanted value by SHA-256 and writes only a missing or differing
one, from standard input; no value is shown in its output. Before anything else,
the role refuses a Redis password holding anything but A-Z, a-z, 0-9 and
`. _ ~ -`, because the password goes into the broker URL unencoded. It sets
`web_secrets_written` to the names it wrote, for W5. A check run predicts each
write by name without making it.

W4 sets up the host's pieces, as root, except that the certificate folder and files
are written as the account and `deploy-site` is read as the account, because root
never follows a path inside the checkout. It first installs `python3-cryptography`,
which `community.crypto`'s modules need on the managed machine. It then reads the
origin certificate and key from `web_origin_certificate` and `web_origin_key`, and
refuses a key that doesn't belong to the certificate before writing either. It sets
`net.ipv4.ip_unprivileged_port_start` to 80, live and in
`/etc/sysctl.d/99-podman-ports.conf`, so rootless containers can publish 80 and 443.
It opens each service in `web_firewall_services` in zone `public`, at runtime and
permanently, and never closes one, so an empty list changes nothing. It writes the
pair into the site checkout's `deploy/certs/`: the folder 0750, `origin.pem` 0644 and
`origin.key` 0600, all owned by the account, with no value in the output. It
registers `web_origin_written` for W5. It reads the checkout's `deploy/deploy-site.sh`
as the account and installs that content as `/usr/local/bin/deploy-site`, root's and
0755. When `web_deploy_key` isn't
empty, it writes that line to `/etc/ssh/authorized_keys/<account>`, root's and 0644,
in a root-owned 0755 folder. An empty `web_deploy_key` writes and removes nothing. A
check run skips the steps that read the site checkout while the checkout is missing.

Decision 68.1 orders the remaining work: W5 the units, and W6 the verify.
