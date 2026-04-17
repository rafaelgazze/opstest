# Deployment Guide

This document covers first-time setup, deploying new versions, rollback, adding environments, teardown, and troubleshooting.

---

## First-Time Setup

### 1. Bootstrap remote state

The bootstrap module creates the S3 bucket and DynamoDB table that Terraform uses for remote state. Run this once per AWS account.

```bash
cd bootstrap
terraform init
terraform apply
```

Note the outputs — you will need `state_bucket_name` in the next step.

```
Outputs:
state_bucket_name    = "suchapp-terraform-state-123456789012"
dynamodb_table_name  = "suchapp-terraform-locks"
```

### 2. Configure GitHub OIDC

The GitHub Actions workflows authenticate to AWS using OIDC federation. The role ARN is `arn:aws:iam::<ACCOUNT_ID>:role/suchapp-github-actions` and is created by Terraform in step 4.

Before the first pipeline run, add your AWS account ID as a GitHub Actions secret:

1. Go to **Settings > Secrets and variables > Actions** in your repository.
2. Create a secret named `AWS_ACCOUNT_ID` with the value of your 12-digit AWS account ID.

The OIDC provider itself is managed as a Terraform resource (`aws_iam_openid_connect_provider.github` in `terraform/iam.tf`) and is created during `terraform apply`.

### 3. Initialise the main Terraform working directory

The backend is configured at `init` time via `-backend-config` flags (see `terraform/backend.tf`):

```bash
terraform -chdir=terraform init \
  -backend-config="bucket=suchapp-terraform-state-<ACCOUNT_ID>" \
  -backend-config="key=suchapp/dev/terraform.tfstate" \
  -backend-config="region=eu-west-1" \
  -backend-config="dynamodb_table=suchapp-terraform-locks"
```

Replace `<ACCOUNT_ID>` with your 12-digit AWS account ID.

### 4. Build the application and bake the first AMI

Packer requires the compiled JAR to be present at `target/suchapp-0.0.1-SNAPSHOT.jar` before it runs:

```bash
# Build the JAR
mvn clean package

# Initialise Packer plugins
cd packer
packer init app.pkr.hcl

# Bake the AMI
packer build \
  -var "region=eu-west-1" \
  -var "app_version=initial" \
  app.pkr.hcl
```

Note the AMI ID printed at the end of the Packer output, for example:

```
==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.suchapp: AMIs were created:
eu-west-1: ami-0abc1234def56789
```

### 5. Apply the infrastructure

```bash
terraform -chdir=terraform apply \
  -var-file=envs/dev.tfvars \
  -var="ami_id=ami-0abc1234def56789"
```

After a successful apply, the ALB DNS name is available in the outputs:

```bash
terraform -chdir=terraform output alb_dns_name
```

---

## Deploying a New Version

### Build, bake, deploy

```bash
# 1. Build the JAR
mvn clean package

# 2. Bake a new AMI (capture the AMI ID)
cd packer
AMI_ID=$(packer build -machine-readable \
  -var "region=eu-west-1" \
  -var "app_version=$(git rev-parse --short HEAD)" \
  app.pkr.hcl \
  | grep 'artifact,0,id' | cut -d: -f2)
cd ..
echo "New AMI: $AMI_ID"

# 3. Run the blue/green deploy
./scripts/deploy.sh dev "$AMI_ID"
```

The deploy script will print progress to stdout:

```
=== Blue/Green Deploy ===
Environment: dev
AMI: ami-0abc1234def56789
Active: blue (suchapp-dev-blue)
Deploying to: green (suchapp-dev-green)
Created launch template version: 3
Scaling green to 2 instances...
Waiting for health checks...
  0/2 healthy (0s elapsed)...
  1/2 healthy (10s elapsed)...
  2/2 healthy (20s elapsed)...
All 2 targets healthy in green
Traffic switched to green
Scaling down blue
=== Deployment complete: green is now active ===
```

### Via GitHub Actions

**Automatic build and bake** (push to `main`):

Pushing a commit to `main` triggers the `build.yml` workflow automatically. It:
1. Validates Terraform (fmt, validate, tflint, checkov).
2. Builds the JAR with Maven.
3. Bakes an AMI with Packer (using the commit SHA as `app_version`).
4. Outputs the AMI ID as a workflow artifact.

**Manual deploy** (workflow dispatch):

1. Go to **Actions > Deploy** in the GitHub repository.
2. Click **Run workflow**.
3. Select the target environment (e.g. `dev`).
4. Enter the AMI ID produced by the build workflow.
5. Click **Run workflow**.

The deploy workflow assumes the `suchapp-github-actions` IAM role via OIDC and runs `scripts/deploy.sh`.

---

## Rollback

A rollback is a forward deployment using the previous AMI ID. The deploy script is colour-agnostic — it always scales up the idle ASG and swaps the listener.

```bash
# Find the previous AMI (from Packer tags, AWS console, or your build history)
PREVIOUS_AMI="ami-0PREVIOUS_AMI_ID"

# Deploy the previous version
./scripts/deploy.sh dev "$PREVIOUS_AMI"
```

Because the previously active ASG is only scaled down (not terminated), and the launch template version is immutable, rollback to any previous AMI is simply a re-run of the deploy script.

**Time to restore service**: approximately 60–120 seconds (instance boot + Spring Boot startup + 2 consecutive health checks at 15-second intervals).

---

## Adding a New Environment

Environments are isolated by Terraform state key and `.tfvars` file. The valid environment names are `dev`, `sta`, `acc`, and `prod` (enforced by a variable validation in `variables.tf`).

```bash
# 1. Copy and adjust the dev tfvars
cp terraform/envs/dev.tfvars terraform/envs/sta.tfvars
# Edit sta.tfvars: set environment="sta", adjust CIDRs, instance type, nat_gateway_count, etc.

# 2. Initialise a new Terraform working directory for the new environment
#    (use a different state key)
terraform -chdir=terraform init \
  -reconfigure \
  -backend-config="bucket=suchapp-terraform-state-<ACCOUNT_ID>" \
  -backend-config="key=suchapp/sta/terraform.tfstate" \
  -backend-config="region=eu-west-1" \
  -backend-config="dynamodb_table=suchapp-terraform-locks"

# 3. Apply with the new tfvars
terraform -chdir=terraform apply \
  -var-file=envs/sta.tfvars \
  -var="ami_id=ami-0abc1234def56789"
```

Each environment gets its own VPC, ASGs, ALB, and SSM parameter path (`/suchapp/<env>/...`). Resources are named `suchapp-<env>-*` so there are no naming collisions within the same account.

For production:
- Set `nat_gateway_count = 3` for AZ-independent NAT routing.
- Set `asg_min`, `asg_max`, and `asg_desired` to values appropriate for your load.
- Use a dedicated AWS account for production to enforce strict IAM boundaries.

---

## Teardown

**Scale down before destroying** to avoid ALB deregistration delays:

```bash
# 1. Scale both ASGs to zero
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name suchapp-dev-blue \
  --min-size 0 --max-size 0 --desired-capacity 0
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name suchapp-dev-green \
  --min-size 0 --max-size 0 --desired-capacity 0

# 2. Wait for instances to terminate (optional but recommended)
aws autoscaling wait group-in-service \
  --auto-scaling-group-names suchapp-dev-blue suchapp-dev-green

# 3. Destroy all resources
terraform -chdir=terraform destroy \
  -var-file=envs/dev.tfvars \
  -var="ami_id=ami-placeholder"
```

**Note**: The bootstrap S3 bucket has `prevent_destroy = true` in its lifecycle. To delete it you must first remove that protection by editing `bootstrap/main.tf`, then run `terraform destroy` in the bootstrap directory.

---

## Troubleshooting

### Health check failures during deploy

**Symptom**: Deploy script times out with `ERROR: Targets not healthy within 300s. Rolling back.`

**Checks**:
- Is the application starting correctly? Use SSM Session Manager to log into a green instance and inspect the systemd journal:
  ```bash
  aws ssm start-session --target <instance-id>
  # On the instance:
  sudo journalctl -u suchapp -f
  ```
- Is the health check path correct? The ALB checks `GET /hello` on port 8080. Verify the app returns HTTP 200 on that path.
- Are there missing SSM parameters? The app reads `/suchapp/<env>/suchname` at startup. A missing parameter will cause the app to fail to start.
- Is the security group allowing traffic from the ALB? The EC2 SG must allow inbound TCP/8080 from the ALB SG.

### SSM Session Manager — access denied

**Symptom**: `aws ssm start-session` returns an access denied error.

**Checks**:
- The EC2 instance must have the `AmazonSSMManagedInstanceCore` policy attached to its role. Verify the instance profile in the AWS console or with:
  ```bash
  aws iam list-attached-role-policies --role-name suchapp-dev-ec2-role
  ```
- The SSM agent must be running. Amazon Linux 2 ships with the SSM agent pre-installed. Verify with:
  ```bash
  # From EC2 console (requires reachability via another path first)
  systemctl status amazon-ssm-agent
  ```
- Check AWS Systems Manager > Fleet Manager — the instance should appear as "Online".

### Instances not starting

**Symptom**: EC2 instances launch but the ASG health check fails immediately.

**Checks**:
- Check the EC2 instance system log in the AWS console (Actions > Monitor and troubleshoot > Get system log).
- Verify the AMI ID is valid in the target region:
  ```bash
  aws ec2 describe-images --image-ids <ami-id>
  ```
- Check that the Packer build succeeded and the JAR was present at `target/suchapp-0.0.1-SNAPSHOT.jar` when Packer ran.
- Inspect the user-data script output — it is logged to `/var/log/cloud-init-output.log` on the instance.

### Timeout during deploy — instances stay unhealthy

**Symptom**: Some (but not all) green instances are healthy but the count never reaches desired.

**Checks**:
- Check the health check interval and thresholds in `terraform/alb.tf`. The ALB requires 2 consecutive successful checks at 15-second intervals (minimum 30s after registration).
- The `health_check_grace_period = 120` on the ASG gives instances 2 minutes before the ASG's own health check fires. The deploy script waits up to 300 seconds.
- If Spring Boot takes more than ~90 seconds to start (e.g. due to a slow database connection), increase `health_check_grace_period` and `MAX_WAIT` in `scripts/deploy.sh`.

### Terraform plan shows unexpected resource replacements

**Symptom**: `terraform plan` shows blue/green ASG or ALB listener will be replaced.

**Cause**: Terraform state has drifted from reality because the deploy script modifies ASG capacity and the ALB listener. Both resources have `lifecycle { ignore_changes = [...] }` to prevent this. If replacements still appear, check whether the `ignore_changes` list covers the changed attributes and whether state was corrupted.

```bash
# Refresh state to sync with live resources
terraform -chdir=terraform refresh \
  -var-file=envs/dev.tfvars \
  -var="ami_id=ami-placeholder"
```
