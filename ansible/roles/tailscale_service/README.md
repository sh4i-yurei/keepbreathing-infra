# tailscale_service

This role makes a machine serve one Tailscale Service. It requires
`tailscale_service_name` and `tailscale_service_port`, and reads the common
`tailnet_domain`. It compares the live serve status with HTTPS on port 443 proxying to
plain HTTP on the given loopback port. If the mapping differs, it clears and serves only
the named Service. The Service definition and policy remain in the Tailscale console.
