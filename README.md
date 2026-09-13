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
tailscale/policy.hujson   the tailnet policy file, as it is in the admin console
ansible/ansible.cfg       runs from the control plane; inventory below
ansible/inventory.ini     the three droplets over the VPC, the two VMs over the tailnet
ansible/playbooks/        one playbook per job
ansible/roles/baseline/   what every box gets before it gets a job
```

## Rules

- No secrets, ever. Not encrypted, not in an example file, not in a commit that was
  later reverted. Secrets come from OpenBao at run time.
- No Terraform state. It lives in MinIO on the hub; `.gitignore` refuses it.
- The policy file here is the record, the admin console is the live copy. Change it
  here first, then paste it there, until Terraform owns that step.
