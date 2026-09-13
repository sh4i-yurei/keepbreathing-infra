# baseline

What every machine gets before it gets a job: patched, auto-updating, hardened SSH,
swap, fail2ban, firewalld, rootless Podman, a persistent journal, and the admin
account. The by-hand version is the server-bootstrap procedure; this role is that
procedure written down so a machine can be rebuilt without anyone remembering it.

Two ways it runs, one variable apart. Against a live box it connects as the admin
account and escalates with a password. Inside a Packer build it connects as root to
a droplet that is about to be destroyed, with `baseline_image_build: true`, and
skips the admin account. No secret is ever in the image; anything secret is applied
to the live box afterwards.

Proven on the hub first, then the droplets.
