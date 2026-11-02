#!/bin/bash
# Preserve existing required-job policy; Linux remains advisory.
status=0
for name in BUILD TEST SWIFTLINT; do
    variable="${name}_RESULT"
    result="${!variable:-}"
    case "$result" in
        success|cancelled|skipped) ;;
        *) echo "$name result is $result"; status=1 ;;
    esac
done
if [[ "${SECURITY_RESULT:-}" != success ]]; then
    echo "Security result is ${SECURITY_RESULT:-unset}; success is required"
    status=1
fi
for name in BUILD_LINUX TEST_LINUX; do
    variable="${name}_RESULT"
    if [[ "${!variable:-}" != success ]]; then
        echo "$name result is ${!variable:-unset} (advisory)"
    fi
done
exit "$status"
