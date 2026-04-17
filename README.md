# suchapp — AWS Blue/Green Deployment Pipeline

A production-ready pipeline for deploying a Spring Boot application ("suchapp") to bare EC2 instances on AWS using a blue/green strategy. Infrastructure is fully defined in Terraform, AMIs are baked with Packer, and deployments are driven by a shell script that swaps an ALB listener between two Auto Scaling Groups with zero downtime. GitHub Actions handles CI (validate, build, bake) and CD (manual dispatch). No long-lived AWS credentials are used anywhere — GitHub authenticates via OIDC federation.

---

## Architecture

```
                          Internet
                             |
                    +--------+--------+
                    |  Application    |
                    |  Load Balancer  |  (public subnets, all 3 AZs)
                    +--------+--------+
                      /              \
              [blue TG]           [green TG]
                  |                    |
     +------------+------+  +-----------+---------+
     |   Private Subnet  |  |   Private Subnet    |
     |   AZ-a  AZ-b AZ-c|  |   AZ-a  AZ-b  AZ-c |
     |  [ EC2 instances ]|  |  [ EC2 instances ]  |
     |   Blue ASG (live) |  |   Green ASG (idle)  |
     +-------------------+  +---------------------+
              |                         |
     +--------+-------------------------+--------+
     |              NAT Gateway(s)               |
     |           (public subnets)                |
     +-------------------------------------------+
              |
     +--------+--------+
     | Internet Gateway |
     +------------------+

VPC CIDR: 10.0.0.0/16
Public subnets:  10.0.1.0/24  10.0.2.0/24  10.0.3.0/24
Private subnets: 10.0.11.0/24 10.0.12.0/24 10.0.13.0/24
```

At any point one ASG serves live traffic; the other is idle (desired=0). A deploy scales up the idle ASG with a new AMI, waits for health checks, atomically swaps the listener, then scales down the old ASG.

See [docs/architecture.md](docs/architecture.md) for component descriptions, design decisions, and a detailed deployment flow diagram.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| AWS account | — |
| Terraform | >= 1.5 |
| Packer | >= 1.9 |
| Java | 11 (Amazon Corretto) |
| Maven | 3.8+ |
| AWS CLI | v2 |

Your AWS CLI profile must have sufficient permissions to run the bootstrap and the first `terraform apply`. Subsequent pipeline runs authenticate via OIDC.

---

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url>
cd opstest

# 2. Bootstrap remote state (creates S3 bucket + DynamoDB table)
cd bootstrap
terraform init
terraform apply
cd ..

# 3. Initialise Terraform with the remote backend
terraform -chdir=terraform init \
  -backend-config="bucket=suchapp-terraform-state-<ACCOUNT_ID>" \
  -backend-config="key=suchapp/dev/terraform.tfstate" \
  -backend-config="region=eu-west-1" \
  -backend-config="dynamodb_table=suchapp-terraform-locks"

# 4. Build the JAR and bake an AMI, then apply infrastructure
mvn clean package
cd packer && packer init app.pkr.hcl && packer build app.pkr.hcl && cd ..
# Note the AMI ID printed by Packer, e.g. ami-0abc1234def56789
terraform -chdir=terraform apply \
  -var-file=envs/dev.tfvars \
  -var="ami_id=ami-0abc1234def56789"

# 5. Deploy (swap the ALB listener to a new AMI)
./scripts/deploy.sh dev ami-0abc1234def56789
```

For a detailed first-time setup, see [docs/deployment.md](docs/deployment.md).

---

## Repository Structure

```
opstest/
├── src/                            # Spring Boot application source
├── pom.xml                         # Maven build descriptor
├── packer/
│   └── app.pkr.hcl                 # Packer template (AMI bake)
├── terraform/
│   ├── backend.tf                  # S3 remote state configuration
│   ├── variables.tf                # Input variables
│   ├── outputs.tf                  # Stack outputs (ALB DNS, etc.)
│   ├── main.tf                     # Provider and data sources
│   ├── vpc.tf                      # VPC, subnets, NAT, IGW
│   ├── alb.tf                      # ALB, target groups, HTTP listener
│   ├── asg.tf                      # Launch template, blue/green ASGs
│   ├── iam.tf                      # EC2 role, GitHub OIDC federation
│   ├── ssm.tf                      # Parameter Store resources
│   ├── security_groups.tf          # Security group definitions
│   ├── .tflint.hcl                 # tflint configuration (AWS ruleset)
│   ├── .checkov.yml                # checkov configuration (CIS/security)
│   ├── envs/
│   │   └── dev.tfvars              # Dev environment variable values
│   └── tests/
│       └── validate_plan.sh        # Plan assertion tests
├── bootstrap/
│   └── main.tf                     # One-time S3 + DynamoDB bootstrap
├── scripts/
│   └── deploy.sh                   # Blue/green deploy script
├── .github/workflows/
│   ├── build.yml                   # Push: validate TF + build JAR + bake AMI
│   ├── deploy.yml                  # Manual dispatch: blue/green swap
│   └── codeql-analysis.yml         # CodeQL security scanning
└── docs/
    ├── architecture.md
    ├── deployment.md
    ├── multi-region.md
    └── future-improvements.md
```

---

## Deployment Overview

### Deploy a new version

```bash
./scripts/deploy.sh <environment> <ami_id>
# Example:
./scripts/deploy.sh dev ami-0abc1234def56789
```

The script:
1. Determines which ASG is active (blue or green) via the `Active` tag.
2. Creates a new launch template version pointing to the new AMI.
3. Scales up the idle ASG to match the active ASG's desired capacity.
4. Polls the ALB target group health check (`GET /hello`) until all targets are healthy.
5. Atomically swaps the ALB listener's default action to the new target group.
6. Scales the old ASG down to zero.
7. Updates `Active` tags on both ASGs.

### Rollback

Re-run `deploy.sh` with the previous AMI ID. The script treats the current live ASG as "active" and promotes the idle slot — it does not care which color is which.

```bash
./scripts/deploy.sh dev ami-0PREVIOUS_AMI
```

---

## Multi-Environment

Environments are driven by `.tfvars` files under `terraform/envs/`. Only `dev` is currently deployed. To add a new environment:

1. Copy `terraform/envs/dev.tfvars` to `terraform/envs/<env>.tfvars` and adjust values.
2. Run `terraform init` with a new state key (`-backend-config="key=suchapp/<env>/terraform.tfstate"`).
3. Run `terraform apply -var-file=envs/<env>.tfvars -var="ami_id=<ami>"`.

See [docs/deployment.md — Adding a new environment](docs/deployment.md#adding-a-new-environment) for the full walkthrough.

---

## Testing

### Terraform validation

```bash
cd terraform

# Format check
terraform fmt -check -recursive

# Static validation
terraform init -backend=false
terraform validate

# AWS-specific linting
tflint --config .tflint.hcl

# Security / CIS checks
checkov -d . --config-file .checkov.yml --framework terraform
```

### Plan validation tests

After generating a plan JSON, the `validate_plan.sh` script asserts expected resource counts and confirms the plan contains no deletions:

```bash
cd terraform
terraform init -backend-config=...
terraform plan -var-file=envs/dev.tfvars -var="ami_id=ami-xxx" -out=plan.bin
terraform show -json plan.bin > plan.json
./tests/validate_plan.sh plan.json
```

---

## Out of Scope

The following topics are out of scope for the current implementation but are documented with concrete implementation paths in [docs/future-improvements.md](docs/future-improvements.md):

- **Monitoring**: CloudWatch dashboards, alarms, and SNS notifications.
- **Centralised logging**: CloudWatch Logs agent, log groups, and ELK/OpenSearch options.
- **HTTPS**: ACM certificate, HTTPS listener on port 443, HTTP-to-HTTPS redirect.
- **Auto-scaling policies**: Target tracking and scheduled scaling.
- **CI/CD enhancements**: Test stages, promotion gates, canary deployments.
- **Cost optimisation**: Spot instances, scheduled dev scale-down, reserved instances.

Multi-region deployment is not yet implemented. See [docs/multi-region.md](docs/multi-region.md) for the planned approach.
