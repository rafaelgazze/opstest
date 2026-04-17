#!/usr/bin/env bash
set -euo pipefail

PLAN_JSON="${1:?Usage: validate_plan.sh <plan.json>}"
ERRORS=0

assert_resource_count() {
  local resource_type="$1"
  local expected="$2"
  local actual
  actual=$(jq "[.planned_values.root_module.resources[] | select(.type == \"$resource_type\")] | length" "$PLAN_JSON")
  if [ "$actual" -ne "$expected" ]; then
    echo "FAIL: Expected $expected $resource_type, got $actual"
    ERRORS=$((ERRORS + 1))
  else
    echo "PASS: $resource_type count = $actual"
  fi
}

echo "=== Terraform Plan Validation ==="

# VPC and Networking
assert_resource_count "aws_vpc" 1
assert_resource_count "aws_subnet" 6
assert_resource_count "aws_internet_gateway" 1
assert_resource_count "aws_nat_gateway" 1

# Load Balancer
assert_resource_count "aws_lb" 1
assert_resource_count "aws_lb_target_group" 2
assert_resource_count "aws_lb_listener" 1

# Compute
assert_resource_count "aws_autoscaling_group" 2
assert_resource_count "aws_launch_template" 1

# Security
assert_resource_count "aws_security_group" 2

# IAM
assert_resource_count "aws_iam_role" 2
assert_resource_count "aws_iam_instance_profile" 1

# SSM
assert_resource_count "aws_ssm_parameter" 1

# No deletions
DELETIONS=$(jq '[.resource_changes[] | select(.change.actions[] == "delete")] | length' "$PLAN_JSON")
if [ "$DELETIONS" -gt 0 ]; then
  echo "FAIL: Plan contains $DELETIONS resource deletions"
  ERRORS=$((ERRORS + 1))
else
  echo "PASS: No resource deletions"
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "=== $ERRORS assertions FAILED ==="
  exit 1
fi

echo "=== All assertions PASSED ==="
