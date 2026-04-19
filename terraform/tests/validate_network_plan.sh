#!/usr/bin/env bash
set -euo pipefail

PLAN_JSON="${1:?Usage: validate_network_plan.sh <plan.json>}"
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

echo "=== Network Plan Validation ==="

assert_resource_count "aws_vpc" 1
assert_resource_count "aws_subnet" 6
assert_resource_count "aws_internet_gateway" 1
assert_resource_count "aws_nat_gateway" 1
assert_resource_count "aws_eip" 1
assert_resource_count "aws_route_table" 2
assert_resource_count "aws_route_table_association" 6

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
