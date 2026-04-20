#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?Usage: deploy.sh <environment> <ami_id>}"
AMI_ID="${2:?Usage: deploy.sh <environment> <ami_id>}"
PROJECT="suchapp"
MAX_WAIT=300

echo "=== Blue/Green Deploy ==="
echo "Environment: $ENVIRONMENT"
echo "AMI: $AMI_ID"

# 1. Find ASGs by name
BLUE_ASG="${PROJECT}-${ENVIRONMENT}-blue"
GREEN_ASG="${PROJECT}-${ENVIRONMENT}-green"

# 2. Determine active color
BLUE_ACTIVE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$BLUE_ASG" \
  --query "AutoScalingGroups[0].Tags[?Key=='Active'].Value|[0]" \
  --output text)

if [ "$BLUE_ACTIVE" = "true" ]; then
  ACTIVE_ASG="$BLUE_ASG"
  INACTIVE_ASG="$GREEN_ASG"
  ACTIVE_COLOR="blue"
  INACTIVE_COLOR="green"
else
  ACTIVE_ASG="$GREEN_ASG"
  INACTIVE_ASG="$BLUE_ASG"
  ACTIVE_COLOR="green"
  INACTIVE_COLOR="blue"
fi

echo "Active: $ACTIVE_COLOR ($ACTIVE_ASG)"
echo "Deploying to: $INACTIVE_COLOR ($INACTIVE_ASG)"

# 3. Get launch template ID
LT_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$INACTIVE_ASG" \
  --query "AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId" \
  --output text)

# 4. Create new launch template version with new AMI
NEW_LT_VERSION=$(aws ec2 create-launch-template-version \
  --launch-template-id "$LT_ID" \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"$AMI_ID\"}" \
  --query "LaunchTemplateVersion.VersionNumber" \
  --output text)

echo "Created launch template version: $NEW_LT_VERSION"

# 5. Get active ASG desired capacity
DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ACTIVE_ASG" \
  --query "AutoScalingGroups[0].DesiredCapacity" \
  --output text)

# 6. Scale up inactive ASG
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$INACTIVE_ASG" \
  --min-size "$DESIRED" \
  --max-size "$DESIRED" \
  --desired-capacity "$DESIRED" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=$NEW_LT_VERSION"

echo "Scaling $INACTIVE_COLOR to $DESIRED instances..."

# 7. Get inactive target group ARN
INACTIVE_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${PROJECT}-${ENVIRONMENT}-${INACTIVE_COLOR}" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

# 8. Get listener ARN (needed for health check trick and final swap)
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-${ENVIRONMENT}" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[0].ListenerArn" \
  --output text)

ACTIVE_TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${PROJECT}-${ENVIRONMENT}-${ACTIVE_COLOR}" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

# 9. Temporarily add inactive TG to listener so ALB health-checks it
# ALB only health-checks target groups referenced by a listener rule.
# Use a weighted forward action: 99% to active, 1% to inactive.
aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --default-actions "[{
    \"Type\": \"forward\",
    \"ForwardConfig\": {
      \"TargetGroups\": [
        {\"TargetGroupArn\": \"$ACTIVE_TG_ARN\", \"Weight\": 99},
        {\"TargetGroupArn\": \"$INACTIVE_TG_ARN\", \"Weight\": 1}
      ]
    }
  }]" > /dev/null

echo "Added $INACTIVE_COLOR TG to listener (1% weight) for health checking..."

# 10. Wait for ALB health checks on inactive TG
echo "Waiting for health checks..."
ELAPSED=0
HEALTHY=0
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  HEALTHY=$(aws elbv2 describe-target-health \
    --target-group-arn "$INACTIVE_TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text)
  if [ "$HEALTHY" -ge "$DESIRED" ]; then
    echo "All $HEALTHY targets healthy in $INACTIVE_COLOR"
    break
  fi
  echo "  $HEALTHY/$DESIRED healthy (${ELAPSED}s elapsed)..."
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

if [ "$HEALTHY" -lt "$DESIRED" ]; then
  echo "ERROR: Targets not healthy within ${MAX_WAIT}s. Rolling back."
  # Restore listener to active-only
  aws elbv2 modify-listener \
    --listener-arn "$LISTENER_ARN" \
    --default-actions "Type=forward,TargetGroupArn=$ACTIVE_TG_ARN" > /dev/null
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$INACTIVE_ASG" \
    --min-size 0 --max-size 0 --desired-capacity 0
  exit 1
fi

# 11. Swap listener fully to inactive target group
aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$INACTIVE_TG_ARN" > /dev/null

echo "Traffic switched to $INACTIVE_COLOR"

# 12. Scale down old ASG
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ACTIVE_ASG" \
  --min-size 0 --max-size 0 --desired-capacity 0

echo "Scaling down $ACTIVE_COLOR"

# 13. Update Active tags
aws autoscaling create-or-update-tags --tags \
  "ResourceId=$INACTIVE_ASG,ResourceType=auto-scaling-group,Key=Active,Value=true,PropagateAtLaunch=true"
aws autoscaling create-or-update-tags --tags \
  "ResourceId=$ACTIVE_ASG,ResourceType=auto-scaling-group,Key=Active,Value=false,PropagateAtLaunch=true"

echo "=== Deployment complete: $INACTIVE_COLOR is now active ==="
