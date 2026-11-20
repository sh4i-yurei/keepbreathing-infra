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

Decision 68.1 orders the remaining work: W4 the host's pieces, W5 the units, and
W6 the verify.
