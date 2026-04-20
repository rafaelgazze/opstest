# Multi-Region Deployment Path

suchapp currently runs in a single AWS region (`eu-west-1`). This document describes the architecture changes required to extend the pipeline to multiple regions, with concrete code examples and operational considerations.

---

## Current Architecture Summary

All infrastructure — VPC, ALB, ASGs, SSM parameters, and IAM — is deployed to a single region. The Terraform configuration is split into two layers: `terraform/network/` (VPC, subnets, NAT) and `terraform/app/` (ALB, ASGs, IAM, SSM). The GitHub Actions pipeline bakes a single AMI in `eu-west-1` and automatically deploys to dev.

```
GitHub Actions
     |
     ├── Bake AMI (eu-west-1)
     └── Deploy  (eu-west-1)
                  |
           [eu-west-1 stack]
           VPC / ALB / ASG
```

---

## 5-Step Path to Multi-Region

### Step 1: Extract Terraform into a reusable module

Refactor the current `terraform/network/` and `terraform/app/` layers into reusable modules at `terraform/modules/network/` and `terraform/modules/app/`. Each module accepts `region` as an input variable and manages all per-region resources for its layer.

```
terraform/
├── modules/
│   ├── network/
│   │   ├── main.tf
│   │   ├── vpc.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── app/
│       ├── main.tf
│       ├── alb.tf
│       ├── asg.tf
│       ├── iam.tf
│       ├── ssm.tf
│       ├── security_groups.tf
│       ├── variables.tf
│       └── outputs.tf
└── root/
    ├── main.tf          # instantiates modules per region
    ├── variables.tf
    └── outputs.tf
```

### Step 2: Multi-provider configuration

Declare one AWS provider alias per target region in the root module. Pass the provider to each module instance.

```hcl
# terraform/root/main.tf

provider "aws" {
  alias  = "eu_west_1"
  region = "eu-west-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "eu_west_1" {
  source = "../modules/suchapp-stack"

  providers = {
    aws = aws.eu_west_1
  }

  environment = var.environment
  region      = "eu-west-1"
  ami_id      = var.ami_id_eu_west_1

  vpc_cidr             = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

module "us_east_1" {
  source = "../modules/suchapp-stack"

  providers = {
    aws = aws.us_east_1
  }

  environment = var.environment
  region      = "us-east-1"
  ami_id      = var.ami_id_us_east_1

  # Use non-overlapping CIDRs if VPC peering is ever required
  vpc_cidr             = "10.1.0.0/16"
  public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  private_subnet_cidrs = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]
}
```

Each module instance maintains independent state. Use separate state keys per region:

```
suchapp/dev/eu-west-1/terraform.tfstate
suchapp/dev/us-east-1/terraform.tfstate
```

### Step 3: Route 53 latency-based routing

Add a Route 53 hosted zone and latency alias records that route users to the nearest healthy region.

```hcl
# terraform/root/dns.tf

resource "aws_route53_zone" "main" {
  name = "suchapp.example.com"
}

resource "aws_route53_record" "eu_west_1" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "suchapp.example.com"
  type    = "A"

  set_identifier = "eu-west-1"

  latency_routing_policy {
    region = "eu-west-1"
  }

  alias {
    name                   = module.eu_west_1.alb_dns_name
    zone_id                = module.eu_west_1.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "us_east_1" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "suchapp.example.com"
  type    = "A"

  set_identifier = "us-east-1"

  latency_routing_policy {
    region = "us-east-1"
  }

  alias {
    name                   = module.us_east_1.alb_dns_name
    zone_id                = module.us_east_1.alb_zone_id
    evaluate_target_health = true
  }
}
```

With `evaluate_target_health = true`, Route 53 will stop routing to a region if all ALB targets in that region are unhealthy.

### Step 4: AMI copy in the pipeline

AMIs are region-specific. After Packer bakes the primary AMI in the source region, copy it to each target region before deploying.

```yaml
# .github/workflows/build.yml (additions to the bake job)

- name: Copy AMI to us-east-1
  id: copy_ami
  run: |
    US_AMI=$(aws ec2 copy-image \
      --source-region eu-west-1 \
      --source-image-id "${{ steps.packer.outputs.ami_id }}" \
      --region us-east-1 \
      --name "suchapp-${{ github.sha }}-us-east-1" \
      --query "ImageId" \
      --output text)
    echo "ami_id_us_east_1=$US_AMI" >> "$GITHUB_OUTPUT"

- name: Wait for AMI copy to complete
  run: |
    aws ec2 wait image-available \
      --region us-east-1 \
      --image-ids "${{ steps.copy_ami.outputs.ami_id_us_east_1 }}"
```

Export both AMI IDs as workflow outputs for consumption by the deploy workflow.

### Step 5: Deploy workflow gains a region matrix

Extend `deploy.yml` to iterate over target regions, deploying to each one in parallel (or sequentially if ordered rollout is preferred).

```yaml
# .github/workflows/deploy.yml

on:
  workflow_dispatch:
    inputs:
      environment:
        required: true
        default: "dev"
        type: choice
        options: [dev, sta, acc, prod]
      ami_id_eu_west_1:
        description: "AMI ID for eu-west-1"
        required: true
        type: string
      ami_id_us_east_1:
        description: "AMI ID for us-east-1"
        required: true
        type: string

jobs:
  deploy:
    strategy:
      matrix:
        include:
          - region: eu-west-1
            ami_input: ami_id_eu_west_1
          - region: us-east-1
            ami_input: ami_id_us_east_1
    name: Deploy (${{ matrix.region }})
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/suchapp-github-actions
          aws-region: ${{ matrix.region }}

      - name: Deploy
        run: |
          chmod +x scripts/deploy.sh
          ./scripts/deploy.sh \
            "${{ inputs.environment }}" \
            "${{ inputs[matrix.ami_input] }}"
        env:
          AWS_DEFAULT_REGION: ${{ matrix.region }}
```

---

## Operational Considerations

### Data replication

suchapp is currently stateless (no database). If a stateful backing store (RDS, DynamoDB, ElastiCache) is added before multi-region is implemented:

- **RDS**: Use Aurora Global Database with a primary writer in one region and read replicas in others. Promote a replica during a regional failover.
- **DynamoDB**: Use Global Tables for active-active replication across regions.
- **ElastiCache**: Use Global Datastore (Redis) or accept that each region has an independent cache.

Treat cross-region data replication as a prerequisite, not an afterthought.

### Session affinity

If the application stores session state in memory (the default for Spring Boot without a session store), users will lose their session when routed from one region to another by Route 53. Options:

- Externalise sessions to a shared DynamoDB Global Table or Redis Global Datastore.
- Use Route 53 health-check failover (not latency routing) so users only move between regions on failure.
- Make the application fully stateless (preferred).

### SSM parameter replication

Each region needs its own SSM parameters under `/suchapp/<env>/...`. The Terraform module creates these in the provider's region. A Parameter Store Advanced Tier cross-region sync is not available; parameters must be maintained independently per region, or created by a shared automation script.

### IAM — OIDC provider

The GitHub OIDC provider (`aws_iam_openid_connect_provider.github`) must exist in each region's AWS account. If all regions share the same account, one OIDC provider is sufficient, but each region needs its own IAM role (or the existing role must have cross-region permissions). For multi-account setups, each account needs its own OIDC provider.

### Cost implications

| Component | Per-region cost (approximate) |
|-----------|------------------------------|
| NAT Gateway (1x) | ~$32/month + data transfer |
| ALB | ~$16/month + LCU charges |
| EC2 instances (2x t3.micro) | ~$17/month |
| Route 53 hosted zone | $0.50/month |
| Route 53 health checks | $0.75/month per check |

Adding a second region approximately doubles the infrastructure cost. For dev environments, consider deploying only to one region and using multi-region exclusively from staging onwards.
