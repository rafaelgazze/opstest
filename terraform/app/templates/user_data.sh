#!/bin/bash
set -euo pipefail

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

SUCHNAME=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/${project}/${environment}/suchname" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)

cat > /opt/app/application.properties <<PROPS
suchname=$SUCHNAME
server.port=${app_port}
PROPS

chown suchapp:suchapp /opt/app/application.properties
systemctl start suchapp
