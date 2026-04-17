# AWS Blue/Green Deployment Pipeline — Design Spec

## Overview

Production-ready zero-downtime deployment pipeline for a Spring Boot application running on bare EC2 instances in AWS. Infrastructure managed with Terraform, AMIs baked with Packer, deployments orchestrated via GitHub Actions.

## Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment strategy | Blue/Green ASG swap | Instant rollback, true zero-downtime |
| IaC | Terraform with tfvars per environment | Explicit, diffable, separate state per env |
| Artifact delivery | Packer AMI baking | Immutable infrastructure, fast boot |
| Multi-region | Design for it, don't build it | Demonstrate understanding, control scope |
| Remote state | S3 + DynamoDB | AWS-native, standard practice |
| Secrets | SSM Parameter Store | Free, least-privilege, no secrets in AMIs |
| CI/CD runner | GitHub Actions | Already in use, OIDC for AWS auth |
| Shell access | SSM Session Manager | No SSH keys, no bastion, audit trail |
| Environments deployed | Dev only | Cost-effective demo, docs explain multi-env |
| Testing | tflint + checkov + plan validation | Defense-in-depth IaC quality |

## 1. Network Architecture

### VPC (one per environment, only dev deployed)

- CIDR parameterized per env (e.g., `10.0.0.0/16` for dev)
- 3 Availability Zones used (a, b, c)
- **Public subnets (3):** ALB and NAT Gateways
- **Private subnets (3):** EC2 instances (no public IPs, no direct internet access)
- **NAT Gateway per AZ:** outbound internet for instances, survives AZ loss
- **Internet Gateway:** for ALB and NAT Gateway

### Security Groups

- **ALB SG:** inbound 80/443 from `0.0.0.0/0`, outbound to EC2 SG on port 8080
- **EC2 SG:** inbound 8080 from ALB SG only, outbound to NAT for internet
- No SSH access — SSM Session Manager used for shell access

### Key Properties

- Instances in private subnets are not directly reachable from the internet
- 3 AZs means the system survives full AZ loss (2 remaining AZs serve traffic)
- NAT per AZ avoids cross-AZ NAT dependency

## 2. Compute & Deployment

### AMI Baking (Packer)

- Base AMI: Amazon Linux 2
- Pre-installed: Java 11, CloudWatch agent, SSM agent (pre-installed on AL2)
- Spring Boot JAR copied to `/opt/app/suchapp.jar`
- systemd service (`suchapp.service`) starts the app on boot
- User data script at boot: reads config from SSM Parameter Store, writes `application.properties`, then starts the service

### Blue/Green ASG Setup

- Two Auto Scaling Groups: `blue` and `green`
- Two ALB Target Groups: `tg-blue` and `tg-green`
- ALB Listener forwards to whichever target group is "active"
- Each ASG spans 3 AZs (one private subnet per AZ)
- Launch template references the Packer AMI ID
- ASG min/max/desired parameterized per env in tfvars

### Deployment Flow

1. GitHub Actions builds JAR with Maven, bakes new AMI with Packer
2. Deployment script determines which ASG is currently inactive (reads ASG tag)
3. Updates inactive ASG's launch template with new AMI ID
4. Sets inactive ASG desired count to match active
5. Waits for instances to pass ALB health checks
6. Swaps ALB listener forward rule to the new target group
7. Scales down old ASG to 0
8. Tags new ASG as "active"

### Rollback

Swap ALB listener back to the previous target group. If within rollback window, old instances are still running. Otherwise, scale old ASG back up from its known-good AMI.

### AZ Display

The Spring Boot `/hello` endpoint reads the EC2 instance metadata endpoint (`http://169.254.169.254/latest/meta-data/placement/availability-zone`) at startup and includes the AZ in the response. Response format: `hello Daniel from us-east-1a`.

## 3. IAM & Security

### EC2 Instance Role

Least-privilege policies:
- `ssm:GetParameter` scoped to `/suchapp/{env}/*`
- `AmazonSSMManagedInstanceCore` for SSM Session Manager
- `logs:PutLogEvents`, `logs:CreateLogStream` for CloudWatch (future)

### GitHub Actions OIDC Role

- OIDC federation with GitHub's OpenID Connect provider (no long-lived credentials)
- Permissions: Packer AMI build, ASG updates, ALB listener modification, SSM parameter read
- Scoped to specific resources via ARNs and condition keys

### SSM Parameter Store

- `/suchapp/dev/suchname` = "Daniel" (SecureString)
- EC2 reads at boot via user data, writes to `application.properties`
- No secrets baked into AMIs

### Other Security

- EC2 in private subnets, no public IPs
- EBS volumes encrypted with default KMS key
- Default security group unused
- HTTP for dev demo; docs explain how to add HTTPS with ACM

## 4. Multi-Environment Support

### Approach

Single Terraform codebase with per-environment tfvars files. Each environment gets:
- Its own `envs/{env}.tfvars` with environment-specific values
- Its own Terraform state (S3 key: `suchapp/{env}/terraform.tfstate`)
- Same S3 bucket and DynamoDB lock table (created by bootstrap)

### Only Dev Deployed

We deploy dev only to keep costs minimal. Adding a new environment:
1. Create `envs/prod.tfvars` with appropriate values (larger instances, higher ASG counts, different CIDR)
2. Run `terraform apply -var-file=envs/prod.tfvars` with state key `suchapp/prod/terraform.tfstate`

### What Differs Between Environments

| Parameter | Dev | Prod (example) |
|-----------|-----|----------------|
| Instance type | t3.micro | t3.medium |
| ASG min/max | 1/2 | 2/6 |
| NAT Gateways | 1 (cost saving) | 3 (one per AZ) |
| CIDR | 10.0.0.0/16 | 10.1.0.0/16 |

## 5. Multi-Region (Design Only, Not Built)

### Current State

Single-region deployment. Terraform is parameterized with `region` variable.

### Path to Multi-Region

1. Extract Terraform into a reusable module representing one region's stack
2. Instantiate the module per region with different providers
3. Add Route 53 with latency-based routing across regional ALBs
4. AMI copy step in pipeline: copy AMI to target regions before deploy
5. GitHub Actions deploy workflow gains a region matrix

Documented in `docs/multi-region.md` with architecture diagram.

## 6. Project Structure

```
opstest/
├── src/                          # Spring Boot app (existing)
├── pom.xml                       # Maven build (existing)
├── packer/
│   └── app.pkr.hcl              # Packer template for AMI
├── terraform/
│   ├── backend.tf               # S3 remote state config
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Outputs (ALB DNS, etc.)
│   ├── main.tf                  # Root module wiring (provider, data sources)
│   ├── vpc.tf                   # VPC, subnets, NAT, IGW
│   ├── alb.tf                   # ALB, listeners, target groups
│   ├── asg.tf                   # Blue/green ASGs, launch templates
│   ├── iam.tf                   # Roles, policies, instance profiles
│   ├── ssm.tf                   # Parameter Store entries
│   ├── security_groups.tf       # SG definitions
│   ├── .tflint.hcl             # tflint config with AWS plugin
│   ├── .checkov.yml            # checkov config
│   ├── envs/
│   │   └── dev.tfvars          # Dev environment config
│   └── tests/
│       └── validate_plan.sh    # Plan-based assertions
├── bootstrap/
│   └── main.tf                  # Creates S3 bucket + DynamoDB for state
├── scripts/
│   └── deploy.sh                # Blue/green deployment orchestration
├── .github/
│   └── workflows/
│       ├── build.yml            # Build JAR + bake AMI + validate
│       └── deploy.yml           # Blue/green swap
└── docs/
    ├── architecture.md          # Architecture overview with diagrams
    ├── deployment.md            # Step-by-step deploy/rollback/add-env
    ├── multi-region.md          # Path to multi-region
    └── future-improvements.md   # CI/CD, monitoring, logging discussion
```

## 7. GitHub Actions Workflows

### `build.yml` (on push to main)

1. Checkout code
2. Set up Java 11, run `mvn clean package`
3. Configure AWS credentials via OIDC
4. `terraform fmt -check`
5. `terraform validate`
6. `tflint` with AWS ruleset
7. `checkov` security scan
8. Plan-based validation tests
9. Packer AMI build
10. Output AMI ID as artifact

### `deploy.yml` (workflow_dispatch or after build)

1. Configure AWS credentials via OIDC
2. Inputs: environment name, AMI ID
3. Run `deploy.sh` which performs the blue/green swap

### Local Deploy

`./scripts/deploy.sh dev ami-abc123` — same logic, runnable with local AWS credentials.

## 8. Testing & Static Analysis

### tflint

- AWS ruleset enabled
- Catches invalid instance types, deprecated arguments, naming issues
- Config in `terraform/.tflint.hcl`

### checkov

- Scans Terraform for AWS best practice / CIS benchmark violations
- Intentional skips documented with inline `checkov:skip` comments explaining rationale
- Config in `terraform/.checkov.yml`

### Plan-Based Validation

Shell script that:
1. Runs `terraform plan -var-file=envs/dev.tfvars -out=plan.tfplan`
2. Converts to JSON: `terraform show -json plan.tfplan`
3. Asserts:
   - Expected resource counts (3 subnets, 2 ASGs, 2 target groups, etc.)
   - Key properties (instance type, AZ distribution)
   - No unexpected resource deletions

## 9. Documentation

### README.md

- Project overview, prerequisites, quick-start (bootstrap to deploy in 5 steps), repo structure, links to detailed docs

### docs/architecture.md

- ASCII network topology diagram, blue/green flow diagram, component descriptions, design rationale

### docs/deployment.md

- First-time setup, deploy new version, rollback, add new environment, teardown, troubleshooting

### docs/multi-region.md

- Current architecture, what changes, Terraform structural changes, Route 53 setup

### docs/future-improvements.md

- CI/CD enhancements (test stages, approval gates, canary deployments)
- Monitoring (CloudWatch dashboards, alarms, SNS notifications)
- Centralized logging (CloudWatch Logs agent, ELK stack)
- HTTPS with ACM + Route 53
- Auto-scaling policies based on CPU/request metrics

## Out of Scope

- Full CI/CD with test stages and approval gates (discussed in docs)
- Monitoring and alerting (discussed in docs)
- Centralized logging (discussed in docs)
- HTTPS/TLS certificates (documented how to add)
- Multi-region deployment (designed, not built)
- Multiple environments deployed (only dev, docs explain how to add)
