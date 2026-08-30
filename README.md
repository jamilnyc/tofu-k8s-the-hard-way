# Kubernetes The Hard Way — EC2 Infrastructure

OpenTofu code that provisions the 4 Debian 12 machines required by
[Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)'s
prerequisites: `jumpbox`, `server`, `node-0`, `node-1`, all on one VPC.

See `docs/superpowers/specs/2026-08-28-ec2-infra-design.md` for the full design
rationale.

## Prerequisites

- OpenTofu >= 1.7
- An AWS CLI profile with credentials that can create VPC/EC2/IAM-adjacent
  resources (this project assumes `AdministratorAccess`)
- A pre-existing S3 bucket and DynamoDB table for remote state/locking

## Setup

`backend.tf` can't use variables (Terraform backend blocks are evaluated
before any variables are resolved), so before running `tofu init`, edit it
and replace the three `CHANGEME-*` placeholders with your own S3 bucket,
DynamoDB lock table, and AWS CLI profile name.

By default `var.aws_profile` (see `variables.tf`) is `"default"`, matching
the AWS CLI's own default profile name — override it (`-var
aws_profile=your-profile`) if you use a named profile for the provider
itself, separately from the backend's `profile` above.

## Usage

```bash
tofu init      # downloads providers, configures the S3 backend
tofu fmt -check
tofu validate
tofu plan      # shows what would be created — review before applying
```

**This project intentionally never runs `tofu apply` from an agent.** When
you've reviewed the plan output and are ready to actually create the
instances, run `tofu apply` yourself.

## After `apply`

Read the SSH commands and IPs out of the outputs:

```bash
tofu output ssh_commands
tofu output instance_private_ips
```

Use the `jumpbox` entry to SSH in first, then follow KTHW's `02-jumpbox.md`
onward — the private IPs above are what go into the guide's machine
database (`machines.txt`) and `/etc/hosts` entries.

## Destroying

`tofu destroy` tears down every resource this project created (VPC, subnet,
instances, security group, keypair). Nothing outside this project's state is
touched.
