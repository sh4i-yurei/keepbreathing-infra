# journal_gateway

The `journal-gateway.yml` play prepares the hub's public client certificate, then
installs gatewayd on `web`, `mail`, `control`, and `vaultserv`. Its private server
key stays on each source. The source's public server certificate is copied to
`/etc/journal_pull/servers/<host>.crt` on the hub. The gateway socket binds only
the IP in that source's `host_vars` and firewalld allows only the same sources
as its node exporter. The role checks client certificates by default. Decision
58 disables that check on AlmaLinux 10 vaultserv, where gatewayd lacks the
feature, while HTTPS and the hub-only firewall rule remain. The role verifies
package versions, options, socket, firewall, and the expected HTTP response
with and without the hub's client certificate.

## Manual `almaserv` installation

`almaserv` is outside the Ansible inventory. Run these steps on the machines
named; confirm the current tailnet IPs and package versions before starting.
The rendered role templates are
`templates/systemd-journal-gatewayd.socket.conf.j2` and
`templates/systemd-journal-gatewayd.service.conf.j2`. Render them with
`journal_gateway_listen_address=100.116.219.6:19531` and
`journal_gateway_verify_client=false`. The rendered socket drop-in must
contain `ListenStream=100.116.219.6:19531`. The service drop-in must load the
server key and certificate, with `--cert` and `--key`, and omit the hub client
certificate credential and `--trust`.

1. On `almaserv`, install `systemd-journal-remote` and `openssl` only, since
   almaserv is set up by hand and needs no Ansible modules; record
   `rpm -q systemd systemd-journal-remote` and verify their version-release
   matches. Check the installed gatewayd `--help` for `--cert` and `--key`.
2. On `almaserv`, create `/etc/journal_gateway` as root mode `0700`, and
   generate a self-signed server key and certificate with an `IP` subject
   alternative name of `100.116.219.6` and server authentication use. Keep
   `server.key` mode `0600` there. Publish only `server.crt` in
   `/etc/journal_gateway-public/server.crt` mode `0644`. Renew the certificate
   when fewer than 30 days remain, then replace the hub's trust copy.
3. Do not install the hub's client certificate on `almaserv`. Copy the published
   server certificate to `/etc/journal_pull/servers/almaserv.crt` on the hub.
   Transfer only that public server certificate. The hub's private client key
   stays in `/etc/journal_pull/client.key` on the hub.
4. Install the rendered socket and service drop-ins in the matching
   `/etc/systemd/system/systemd-journal-gatewayd.{socket,service}.d/`
   directories as `10-listen-address.conf` and `10-mutual-tls.conf`. Run
   `systemctl daemon-reload`, enable and start
   `systemd-journal-gatewayd.socket`, then verify its bind address.
5. On `almaserv`, allow TCP 19531 in firewalld's public zone only from
   `100.95.89.6/32`, the hub's tailnet IP. Remove stale rich rules on that
   port. Verify the permanent rules and the live listener.
6. From the hub, request `https://100.116.219.6:19531/machine` using
   `--cacert /etc/journal_pull/servers/almaserv.crt`,
   `--cert /etc/journal_pull/client.crt`, and
   `--key /etc/journal_pull/client.key`; require HTTP 200. A request from a
   tailnet address other than the hub's must be refused by firewalld, because
   this gateway does not check client certificates. Then run the hub play to
   start the `almaserv` puller.

Do not apply the gateway play until the source firewall and tailnet grants
are ready. The live run and the manual `almaserv` steps are Claude's work
after review.
