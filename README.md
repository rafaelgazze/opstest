# suchapp — AWS Blue/Green Deployment Pipeline

A production-ready pipeline for deploying a Spring Boot application ("suchapp") to bare EC2 instances on AWS using a blue/green strategy. Infrastructure is fully defined in Terraform, AMIs are baked with Packer, and deployments are driven by a shell script that swaps an ALB listener between two Auto Scaling Groups with zero downtime. GitHub Actions handles the full CI/CD pipeline: pushing to `main` automatically validates Terraform, builds the JAR, bakes an AMI, and deploys via blue/green swap. A manual deploy workflow is also available for rollbacks. No long-lived AWS credentials are used anywhere — GitHub authenticates via OIDC federation.

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

Terraform is split into two independent layers for blast radius isolation:
- **Network layer** (`terraform/network/`): VPC, subnets, NAT gateways, IGW, route tables — rarely changes.
- **App layer** (`terraform/app/`): ALB, ASGs, launch template, security groups, IAM, SSM — changes with each deployment cycle.

The app layer reads network outputs via `terraform_remote_state`.

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

### Installation

**macOS (Homebrew):**

```bash
brew install awscli
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
brew install hashicorp/tap/packer
```

**Linux (Amazon Linux 2 / Ubuntu):**

```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Terraform & Packer
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y terraform packer
```

Verify:

```bash
aws --version && terraform version && packer version
```

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

# 3. Deploy the network layer
terraform -chdir=terraform/network init \
  -backend-config="bucket=suchapp-terraform-state-<ACCOUNT_ID>" \
  -backend-config="key=suchapp/dev/network.tfstate" \
  -backend-config="region=eu-west-1"
terraform -chdir=terraform/network apply -var-file=envs/dev.tfvars

# 4. Build the JAR, bake an AMI, then deploy the app layer
mvn clean package
cd packer && packer init app.pkr.hcl && packer build app.pkr.hcl && cd ..
# Note the AMI ID printed by Packer, e.g. ami-0abc1234def56789
terraform -chdir=terraform/app init \
  -backend-config="bucket=suchapp-terraform-state-<ACCOUNT_ID>" \
  -backend-config="key=suchapp/dev/app.tfstate" \
  -backend-config="region=eu-west-1"
terraform -chdir=terraform/app apply \
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
│   ├── network/                    # Network layer (VPC, subnets, NAT, IGW)
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── vpc.tf
│   │   ├── outputs.tf
│   │   └── envs/
│   │       └── dev.tfvars
│   ├── app/                        # App layer (ALB, ASGs, IAM, SSM)
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── remote_state.tf         # Reads network layer outputs
│   │   ├── alb.tf
│   │   ├── asg.tf
│   │   ├── security_groups.tf
│   │   ├── iam.tf
│   │   ├── ssm.tf
│   │   ├── outputs.tf
│   │   ├── templates/
│   │   │   └── user_data.sh
│   │   └── envs/
│   │       └── dev.tfvars
│   └── tests/
│       ├── validate_network_plan.sh
│       └── validate_app_plan.sh
├── bootstrap/
│   └── main.tf                     # One-time S3 + DynamoDB bootstrap
├── scripts/
│   └── deploy.sh                   # Blue/green deploy script
├── .github/workflows/
│   ├── build.yml                   # Push: validate TF + build JAR + bake AMI + deploy
│   ├── deploy.yml                  # Manual dispatch: rollback or deploy specific AMI
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

Environments are driven by `.tfvars` files under `terraform/network/envs/` and `terraform/app/envs/`. Only `dev` is currently deployed. To add a new environment:

1. Copy the `dev.tfvars` in both `terraform/network/envs/` and `terraform/app/envs/` and adjust values.
2. Run `terraform init` for each layer with a new state key (e.g. `suchapp/sta/network.tfstate` and `suchapp/sta/app.tfstate`).
3. Apply the network layer first, then the app layer.

See [docs/deployment.md — Adding a new environment](docs/deployment.md#adding-a-new-environment) for the full walkthrough.

---

## Testing

### Terraform validation

```bash
# Validate both layers
for layer in network app; do
  cd terraform/$layer
  terraform fmt -check -recursive
  terraform init -backend=false
  terraform validate
  tflint --init --config .tflint.hcl && tflint --config .tflint.hcl
  checkov -d . --config-file .checkov.yml --framework terraform
  cd ../..
done
```

### Plan validation tests

After generating a plan JSON, the validation scripts assert expected resource counts and confirm the plan contains no deletions:

```bash
# Network layer
cd terraform/network
terraform plan -var-file=envs/dev.tfvars -out=plan.bin
terraform show -json plan.bin > plan.json
../tests/validate_network_plan.sh plan.json

# App layer
cd ../app
terraform plan -var-file=envs/dev.tfvars -var="ami_id=ami-xxx" -out=plan.bin
terraform show -json plan.bin > plan.json
../tests/validate_app_plan.sh plan.json
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
