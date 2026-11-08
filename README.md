# keepbreathing-infra

Everything that describes the machines behind keepbreath.ing, as opposed to the
site itself, which lives in the `keepbreathing` repository. Ansible roles and the
inventory, the tailnet policy file, and later Packer templates, Terraform, the hub's
Quadlet units and the alert rules. Operational issues that are not code bugs (a
certificate expiring, a disk filling, the runner not registered) are filed here.

Private on purpose. A repository like this is a map of the estate even with no
secrets in it, and its issues are a live feed of weak moments.

## Layout

```
tailscale/policy.hujson      the tailnet policy file, as it is live in the tailnet
ansible/ansible.cfg          runs from the laptop; inventory below
ansible/inventory.ini        five machines: three on the tailnet, web and mail through the jump server
ansible/group_vars/          what every machine shares, including the sudo password lookup
ansible/host_vars/           one file per machine for what differs
ansible/playbooks/           one playbook per job
ansible/roles/               one role per job: baseline, access, hub, journal_gateway,
                             node_exporter, podman_exporter
ansible/filter_plugins/      Python filters the roles call
ansible/tests/               Python tests for the filters and the roles' scripts
workstation/vm-autostart/    starts and stops the workstation's VMs with Windows
```

`ARCHITECTURE.md` says what each piece owns and how they fit together.

## Rules

- No secrets, ever. Not encrypted, not in an example file, not in a commit that was
  later reverted. Secrets are read at run time: today through `bw` from Vaultwarden, and
  from OpenBao on the hub once it exists, which is where machine secrets belong.
- No Terraform state. It lives in MinIO on the hub; `.gitignore` refuses it.
- The policy file here is the record. After each merge it goes live through Tailscale's
  API, validated first and read back (OpenBao on the hub decision #70).
