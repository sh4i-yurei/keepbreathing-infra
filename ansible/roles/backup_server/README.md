# backup_server

This role runs rclone's REST server as a rootless Quadlet container under its own account. It
serves only the mounted backup disk over loopback. The Quadlet checks the mount before starting
and retries every five seconds until the disk returns. The server accepts authenticated backups
but refuses deletion and confines each login to its own repository path.

The role requires `backup_server_user`, `backup_server_port`, `backup_server_mount_point`, `backup_server_logins`,
`backup_server_verify_password`, and `backup_server_verify_restic_password`. Each login has a
`name` and a bcrypt hash. The `verify` login must be present. The two verification passwords
come from the same vault item as its hash. The role does not create that vault item.

On every real run, the role initializes the verify repository if needed, writes one small backup,
and checks that forgetting a snapshot, deleting a data file, reaching another repository and
making an unauthenticated request are refused. It keeps no Tailscale configuration.
