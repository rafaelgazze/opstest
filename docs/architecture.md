# Architecture

This document describes the infrastructure topology, component responsibilities, blue/green deployment flow, design decisions, and security architecture for the suchapp pipeline.

---

## VPC Topology

```
Region: eu-west-1
VPC: 10.0.0.0/16
┌─────────────────────────────────────────────────────────────────────────────┐
│  VPC                                                                         │
│                                                                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │  Public Subnet  │  │  Public Subnet  │  │  Public Subnet  │             │
│  │  AZ-a           │  │  AZ-b           │  │  AZ-c           │             │
│  │  10.0.1.0/24    │  │  10.0.2.0/24   │  │  10.0.3.0/24    │             │
│  │                 │  │                 │  │                 │             │
│  │  [NAT Gateway]  │  │                 │  │                 │             │
│  │  [ALB node]     │  │  [ALB node]     │  │  [ALB node]     │             │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘             │
│           │                    │                    │                       │
│  ┌────────┴────────┐  ┌────────┴────────┐  ┌────────┴────────┐             │
│  │  Private Subnet │  │  Private Subnet │  │  Private Subnet │             │
│  │  AZ-a           │  │  AZ-b           │  │  AZ-c           │             │
│  │  10.0.11.0/24   │  │  10.0.12.0/24  │  │  10.0.13.0/24   │             │
│  │                 │  │                 │  │                 │             │
│  │  [EC2: blue]    │  │  [EC2: blue]    │  │  [EC2: blue]    │             │
│  │  [EC2: green*]  │  │  [EC2: green*]  │  │  [EC2: green*]  │             │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘             │
│                                                                              │
│  * green instances exist only during a deployment; desired=0 at rest         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
              |
     Internet Gateway
              |
           Internet
```

**NAT Gateway count**: `nat_gateway_count=1` (dev) routes all private subnets through a single NAT in AZ-a. Setting `nat_gateway_count=3` (prod) gives each AZ its own NAT for full AZ independence.

---

## Blue/Green Deployment Flow

```
Step 1: Starting state
  ALB Listener ──► [Blue TG]  (2 healthy instances)
  Green ASG desired = 0

Step 2: Create launch template version
  New LT version with new AMI ID created

Step 3: Scale up green
  Green ASG desired = 2, min = 2  (uses new LT version)
  New EC2 instances boot, JAR starts via systemd

Step 4: Wait for health checks
  ALB polls GET /hello on each green instance
  Script polls until healthy_count >= desired
  Timeout: 300s; on timeout → scale green to 0, exit 1

Step 5: Atomic listener swap
  ALB Listener ──► [Green TG]
  (single API call; in-flight requests on blue complete normally)

Step 6: Scale down blue
  Blue ASG desired = 0, min = 0
  Old instances terminate

Step 7: Update Active tags
  Blue  tag Active = false
  Green tag Active = true

Step 8: End state
  ALB Listener ──► [Green TG]  (2 healthy instances)
  Blue ASG desired = 0
```

On the next deployment the colours reverse: green becomes active, blue is the idle slot. The script reads the `Active` tag at runtime so it does not assume a fixed colour mapping.

---

## Component Descriptions

| Component | Resource(s) | Responsibility |
|-----------|-------------|---------------|
| **VPC** | `aws_vpc`, `aws_subnet` (x6), `aws_internet_gateway`, `aws_nat_gateway`, route tables | Network isolation. Public subnets host the ALB and NAT. Private subnets host EC2. No instance has a public IP. |
| **ALB** | `aws_lb`, `aws_lb_listener` | Terminates HTTP on port 80; forwards to the active target group. One listener; default action is swapped atomically during deployments. |
| **Target Groups** | `aws_lb_target_group` (blue + green) | Each group health-checks `GET /hello` on port 8080. `healthy_threshold=2`, `interval=15s`. |
| **Launch Template** | `aws_launch_template` | Defines AMI, instance type, security group, IAM instance profile, IMDSv2, and user-data. New AMI versions are appended as new LT versions — existing instances are unaffected. |
| **Blue ASG** | `aws_autoscaling_group.blue` | Starts active (`Active=true`, `desired=2`). Terraform `lifecycle.ignore_changes` on capacity and LT prevents Terraform from reverting deploy-script changes. |
| **Green ASG** | `aws_autoscaling_group.green` | Starts idle (`Active=false`, `desired=0`). Promoted to active during each deployment. |
| **SSM Parameter Store** | `aws_ssm_parameter` | Stores application secrets (e.g. `/suchapp/dev/suchname`). EC2 instances read parameters at startup via IAM policy. No secrets are baked into AMIs. |
| **IAM — EC2 role** | `aws_iam_role.ec2`, `aws_iam_instance_profile.ec2` | Allows `ssm:GetParameter` on the env-scoped path. Attaches `AmazonSSMManagedInstanceCore` for SSM Session Manager access. |
| **IAM — GitHub OIDC** | `aws_iam_openid_connect_provider.github`, `aws_iam_role.github_actions` | Allows GitHub Actions to assume a role via OIDC token without storing long-lived credentials. Scoped to `refs/heads/main`. |

---

## Layered Terraform Architecture

The Terraform code is split into two independent layers, each with its own state file:

| Layer | Directory | State key | Contents | Change frequency |
|-------|-----------|-----------|----------|-----------------|
| **Network** | `terraform/network/` | `suchapp/<env>/network.tfstate` | VPC, subnets, NAT gateways, IGW, route tables | Rarely (initial setup) |
| **App** | `terraform/app/` | `suchapp/<env>/app.tfstate` | ALB, ASGs, launch template, security groups, IAM, SSM | Each deployment cycle |

The app layer reads network outputs (VPC ID, subnet IDs) via a `terraform_remote_state` data source. This separation provides:

- **Blast radius isolation** — a misconfigured `terraform destroy` on the app layer cannot accidentally remove the VPC and NAT gateway.
- **Faster applies** — the app layer has fewer resources to plan and refresh.
- **Independent change cadence** — networking is stable infrastructure; the app layer changes with each AMI release.
- **Team boundaries** — a platform team can own the network layer while application teams manage their own app layer.

The deploy order is always **network first, then app**. Teardown is the reverse: **app first, then network**.

---

## Design Decisions

| Decision | Chosen approach | Rationale |
|----------|----------------|-----------|
| **Deployment strategy** | Blue/green with ASG swap | Zero-downtime; instant rollback by re-deploying the previous AMI; no in-place mutations to running instances. Rolling would leave a mixed-version fleet during the window. |
| **AMI baking (Packer) vs. deploy-time artefact** | Packer bakes immutable AMIs | All dependencies (Java, CloudWatch agent, JAR) are sealed into the AMI. Instance startup is fast and predictable. S3-based bootstrap would require each instance to pull the JAR and install dependencies at boot, adding drift risk. |
| **EC2 placement** | Private subnets only | No instance has a public IP. All inbound traffic flows through the ALB. Outbound internet access (SSM, yum, CloudWatch) uses the NAT Gateway. Reduces attack surface. |
| **IMDSv2** | `http_tokens = required` in launch template | Enforces session-oriented metadata requests. Prevents SSRF attacks from using the metadata service to retrieve credentials or user data. |
| **Secrets management** | SSM Parameter Store (`SecureString`) | KMS-encrypted at rest; accessed via IAM policy; no secrets in AMIs or environment variables. Secrets Manager would be appropriate for automatic rotation — SSM is sufficient for the current secret volume. |
| **CI/CD credentials** | GitHub OIDC federation | No IAM user keys to rotate or leak. The GitHub OIDC provider issues a short-lived token per workflow run. The assumed role is scoped to `refs/heads/main`. |
| **SSH / bastion** | None — SSM Session Manager | Eliminates the need for SSH keys, bastion hosts, or open port 22. Audit logs are written to CloudTrail and can be forwarded to CloudWatch Logs. |
| **NAT Gateway count** | Variable (`1` dev, `3` prod) | One NAT is sufficient for dev and costs ~$32/month. For production, one per AZ ensures private subnet traffic survives an AZ failure. |
| **Terraform layering** | Network and app as separate root modules | Blast radius isolation — networking rarely changes and should not be affected by app-layer operations. Enables independent change cadence and team ownership. The app layer reads network outputs via `terraform_remote_state`. |

---

## Security Architecture

### Network isolation

- EC2 instances live exclusively in private subnets. No public IP is assigned.
- The ALB security group allows inbound TCP/80 from `0.0.0.0/0` and egress only to the EC2 security group on `app_port` (8080).
- The EC2 security group allows ingress only from the ALB security group on port 8080, plus egress to `0.0.0.0/0` (required for NAT, SSM endpoint, and `yum`).
- There is no security group rule for SSH (port 22).

### Instance access

Shell access is via AWS Systems Manager Session Manager. The `AmazonSSMManagedInstanceCore` policy is attached to the EC2 role. This provides an auditable, IAM-controlled shell without any network exposure.

### IAM least privilege

- The EC2 role is scoped to `ssm:GetParameter` on `arn:aws:ssm:region:account:parameter/suchapp/env/*`.
- The GitHub Actions role is scoped to the exact API calls needed by Packer (EC2 image operations) and the deploy script (ASG/ELB/LT describe and modify).
- Both roles use separate, narrowly scoped inline policies rather than broad managed policies.

### Metadata service

IMDSv2 is enforced on all instances via the launch template (`http_tokens = required`). Instance metadata is only accessible via a session token obtained with a `PUT` request, preventing credential theft via SSRF.

### State and secrets

- Terraform state is stored in S3 with SSE-KMS and versioning enabled. Public access is blocked at the bucket level.
- State locking uses DynamoDB to prevent concurrent applies.
- Application secrets are stored as `SecureString` parameters in SSM. The `value` field in Terraform uses `lifecycle { ignore_changes = [value] }` so Terraform does not revert out-of-band secret rotations.

### AMI hardening

- The `suchapp` user is a system account (`useradd -r`) with no login shell (`/sbin/nologin`).
- The JAR is owned by `suchapp:suchapp` with permissions `500` (execute only for owner).
- The systemd service runs as the `suchapp` user, not root.
- EBS root volumes are encrypted (enforced by checkov CIS checks in CI).
