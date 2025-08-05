#!/bin/bash
# SwiftLint Report Script

echo "========================================="
echo "         SwiftLint Report Summary         "
echo "========================================="
echo ""

# Run SwiftLint and capture output
LINT_OUTPUT=$(swiftlint lint --config .swiftlint.yml --reporter json 2>/dev/null)

# Count total violations
TOTAL=$(echo "$LINT_OUTPUT" | jq 'length')
ERRORS=$(echo "$LINT_OUTPUT" | jq '[.[] | select(.severity == "error")] | length')
WARNINGS=$(echo "$LINT_OUTPUT" | jq '[.[] | select(.severity == "warning")] | length')

echo "Total Violations: $TOTAL"
echo "  - Errors: $ERRORS"
echo "  - Warnings: $WARNINGS"
echo ""

echo "========================================="
echo "         Violations by Rule              "
echo "========================================="
echo ""

# Group by rule and count
echo "$LINT_OUTPUT" | jq -r 'group_by(.rule_id) | map({rule: .[0].rule_id, count: length, severity: .[0].severity}) | sort_by(-.count) | .[] | "\(.count) \(.severity): \(.rule)"'

echo ""
echo "========================================="
echo "         Error Details (Must Fix)        "
echo "========================================="
echo ""

# Show all errors
echo "$LINT_OUTPUT" | jq -r '.[] | select(.severity == "error") | "\(.file):\(.line):\(.character): \(.rule_id) - \(.reason)"'

echo ""
echo "========================================="
echo "         Top Files with Violations       "
echo "========================================="
echo ""

# Group by file and count
echo "$LINT_OUTPUT" | jq -r 'group_by(.file) | map({file: .[0].file, count: length}) | sort_by(-.count) | .[0:20] | .[] | "\(.count) violations: \(.file | split("/") | .[-1])"'

echo ""
echo "========================================="
echo "         Quick Fixes Available           "
echo "========================================="
echo ""

echo "1. File Header violations (280): All files need copyright headers"
echo "2. Trailing Newline violations (232): Files need single trailing newline"
echo "3. Empty Count violations (53): Use .isEmpty instead of .count == 0"
echo "4. Force Cast violations (23): Replace force casts with safe unwrapping"
echo ""
echo "To fix trailing newlines automatically:"
echo "  swiftlint --fix --config .swiftlint.yml"