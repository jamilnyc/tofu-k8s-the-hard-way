# Kubernetes The Hard Way — EC2 Infrastructure Design

**Date:** 2026-08-28
**Status:** Approved, not yet implemented

## Purpose

Provision the 4 Debian 12 machines required by the [Kubernetes The Hard
Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) prerequisites
(`01-prerequisites.md`, `02-jumpbox.md`, `03-compute-resources.md`) as AWS EC2
instances on a single shared network, defined as OpenTofu code. This covers
infrastructure provisioning only — the KTHW tutorial steps themselves (jumpbox
setup, cert authority, etcd, control plane, workers, etc.) are out of scope
and picked up manually afterward using this infrastructure's outputs.

## Machines

Matches the guide's naming and roles exactly:

| Name | Role | Instance type | Root disk | Private IP |
|---|---|---|---|---|
| jumpbox | administration host | t3.medium | 10GB gp3 | 10.0.1.10 |
| server | Kubernetes control plane | t3.medium | 20GB gp3 | 10.0.1.11 |
| node-0 | Kubernetes worker | t3.medium | 20GB gp3 | 10.0.1.12 |
| node-1 | Kubernetes worker | t3.medium | 20GB gp3 | 10.0.1.13 |

All four use `t3.medium` uniformly (2 vCPU / 4GB) rather than the guide's
smaller jumpbox spec — simpler to manage, and the cost delta is negligible.

**AMI**: latest Debian 12 (bookworm) AMD64 AMI, resolved dynamically via a
data source against Debian's official AMI owner ID (`136693071363`) — no
hardcoded, staleness-prone AMI ID.

## Networking

- New VPC, `10.0.0.0/16`.
- One public subnet, `10.0.1.0/24`, in `us-east-1a`.
- Internet Gateway + route table (`0.0.0.0/0` → IGW) associated with the
  subnet.
- All 4 instances get a static private IP (from the table above, via each
  `aws_instance`'s `private_ip`) and a public IP (`associate_public_ip_address
  = true`), so they're directly SSH-reachable and have stable addresses for
  `/etc/hosts` entries and pod-network routing later in the guide.

### Security group

One SG, applied to all 4 instances:

- Ingress: TCP 22 from **the operator's current public IP only** (`/32`),
  auto-detected at `tofu apply` time via a data source call to a public
  IP-echo service. This is the one outbound call Tofu makes besides AWS
  itself — noted here since it's a deviation from a fully air-gapped/AWS-only
  setup.
- Ingress: all protocols/ports from other members of the same security group
  (self-referencing rule). KTHW's later steps (etcd, kube-apiserver, kubelet,
  pod network, etc.) don't pin down a fixed port list, so intra-cluster
  traffic is opened fully rather than guessing every port up front.
- Egress: all traffic allowed (default).

## SSH access

- Tofu generates an ed25519 keypair (`tls_private_key`), registers the
  public half as an `aws_key_pair`, and writes the private key locally to
  `./ssh/id_ed25519` (mode `0600`, git-ignored).
- Root SSH login is enabled on all 4 instances via cloud-init `user_data`:
  the generated public key is injected into `/root/.ssh/authorized_keys` and
  `PermitRootLogin yes` is set in `sshd_config`. This matches the guide's
  assumption that keys are distributed from the jumpbox as root
  (`03-compute-resources.md`) — a deliberate reduction in default hardening,
  acceptable for this disposable learning cluster.

## State backend

Remote state in S3 with DynamoDB locking:

```hcl
terraform {
  backend "s3" {
    bucket         = "CHANGEME-terraform-state-bucket"
    key            = "k8s-hard-way.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
    profile        = "CHANGEME-aws-profile"
  }
}
```

The `CHANGEME-aws-profile` AWS profile's IAM user has `AdministratorAccess`, so
no additional bucket/table permissions need to be granted.

## Provider / auth

`provider "aws" { region = var.region; profile = "CHANGEME-aws-profile" }`.
Region defaults to `us-east-1`.

## File layout

```
k8s-hard-way/
├── backend.tf        # S3 backend config
├── versions.tf        # required_providers / required_version
├── main.tf             # provider, VPC, subnet, IGW, route table, SG
├── instances.tf          # key pair, AMI data source, 4x aws_instance
├── variables.tf            # region, instance_type, cidrs, private IPs
├── outputs.tf                # public/private IPs, ready-to-paste ssh commands
├── cloud-init.yaml             # templated user-data enabling root SSH
├── .gitignore                    # ssh/, *.tfstate*, .terraform/
└── README.md                       # init/plan/apply instructions, how outputs
                                      feed into the KTHW guide's next steps
```

## Out of scope

- Any KTHW tutorial step beyond machine provisioning (cert authority, etcd,
  kubeconfig, pod network routes, etc.).
- Multi-AZ, autoscaling, or production-hardening concerns — this is a
  single-operator learning environment.
- CI/CD or automated `tofu apply` — applied manually by the user.
