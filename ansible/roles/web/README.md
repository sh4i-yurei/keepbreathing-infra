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

Decision 67 divides the remaining work into W3 through W6: secrets, unit links
and candidate contact API deploy, port boundary and deployment credentials,
then live-state and relay verification.
