# Web role

W1 creates the container account in the separate `account` entry point. The main
entry point installs git and clones the site and contact API into account-owned
folders under `/srv` only when they are missing. It leaves existing checkouts at
their current commits. It refuses an occupied path that is not a checkout and
requires the site's container unit to publish its server on loopback.

Decision 67 divides the rest of the role into W2 through W6. Those items add the
network and relay drop-in, secrets, unit links and candidate contact API deploy,
port boundary and deployment credentials, then live-state and relay verification.
