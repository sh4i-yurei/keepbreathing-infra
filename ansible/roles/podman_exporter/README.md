# podman_exporter

This role runs the digest-pinned Podman exporter as a rootless Quadlet container under the same
account as a machine's workload containers. It enables that account's Podman socket, mounts only
that socket and the exporter's web configuration, and enables the image, system and volume
collectors used by Container Resources.

Every enabled host requires basic authentication. Droplets also get a machine-made self-signed
certificate; tailnet-only hosts use the tailnet's encryption. Firewalld admits only the addresses
in `podman_exporter_allowed_sources` and removes obsolete rules for port 9882. The role verifies
authentication, TLS where enabled, the pinned image, every expected container, and the permanent
and runtime firewall rules. Web's DigitalOcean cloud firewall separately admits TCP 9882 only from
the control plane's VPC address, `10.128.0.5`; that cloud rule is managed through the API, outside
this repository.

The image is v2.0.0. Its installed help names `--web.config.file` for TLS or authentication, and
its install guide gives the rootless socket mount, `keep-id:uid=65534` user namespace and
`container_runtime_t` SELinux label used by the Quadlet template.
