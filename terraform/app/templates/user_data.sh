#!/bin/bash
set -euo pipefail
exec > /var/log/user-data.log 2>&1

echo "User data script starting at $(date)"

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "Region: $REGION"

# Retry SSM parameter fetch — IAM role may take a few seconds to propagate
RETRIES=0
MAX_RETRIES=10
until SUCHNAME=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/${project}/${environment}/suchname" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text 2>&1); do
  RETRIES=$((RETRIES + 1))
  if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Failed to fetch SSM parameter after $MAX_RETRIES attempts: $SUCHNAME"
    exit 1
  fi
  echo "SSM fetch attempt $RETRIES failed, retrying in 5s..."
  sleep 5
done

echo "SSM parameter fetched: suchname=$SUCHNAME"

cat > /opt/app/application.properties <<PROPS
suchname=$SUCHNAME
server.port=${app_port}
PROPS

chown suchapp:suchapp /opt/app/application.properties
echo "Starting suchapp service..."
systemctl start suchapp
echo "User data script completed at $(date)"
