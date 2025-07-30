#!/bin/bash
# Script to run stress tests with Thread Sanitizer

set -e

echo "Running Stress Test Framework Tests"
echo "=================================="

# Set TSan options
export TSAN_OPTIONS="suppressions=$(pwd)/tsan.suppressions"

# Run core tests without TSan first
echo ""
echo "Running Core Tests (without TSan)..."
swift test --filter StressTestCore

# Run TSan tests
echo ""
echo "Running TSan Tests..."
swift test --configuration debug --filter StressTestTSan --sanitize thread

echo ""
echo "All tests completed!"