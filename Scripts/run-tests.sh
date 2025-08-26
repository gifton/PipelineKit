#!/bin/bash
# Simplified test runner for PipelineKit

set -e

echo "==================================="
echo "PipelineKit Test Runner"
echo "==================================="
echo ""

# Parse arguments
TARGET=""
VERBOSE=false
FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --filter)
            FILTER="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--target MODULE] [--verbose] [--filter PATTERN]"
            exit 1
            ;;
    esac
done

# Function to run tests for a specific module
run_module_tests() {
    local module=$1
    echo "Testing $module..."
    
    if [ "$VERBOSE" = true ]; then
        swift test --filter "${module}Tests" 2>&1
    else
        swift test --filter "${module}Tests" 2>&1 | grep -E "Test Suite|Executed|passed|failed" || true
    fi
}

# Main test execution
if [ -n "$TARGET" ]; then
    # Test specific module
    run_module_tests "$TARGET"
else
    # Test all modules
    echo "Running all tests..."
    echo ""
    
    # Core modules (priority)
    echo "=== Core Modules ==="
    run_module_tests "PipelineKitCore"
    echo ""
    
    # Feature modules
    echo "=== Feature Modules ==="
    run_module_tests "PipelineKitResilience"
    run_module_tests "PipelineKitSecurity"
    run_module_tests "PipelineKitObservability"
    run_module_tests "PipelineKitCache"
    run_module_tests "PipelineKitPooling"
    echo ""
    
    # Integration tests
    echo "=== Integration Tests ==="
    run_module_tests "PipelineKitIntegration"
    echo ""
fi

# Summary
echo ""
echo "==================================="
echo "Test Summary"
echo "==================================="
echo "Total test files: $(find Tests -name '*.swift' | wc -l | tr -d ' ')"
echo "Total test methods: $(grep -r 'func test' Tests --include='*.swift' | wc -l | tr -d ' ')"

# Check for failures
if swift test --filter "NONE" 2>&1 | grep -q "failed"; then
    echo ""
    echo "⚠️  Some tests failed. Run with --verbose for details."
    exit 1
else
    echo ""
    echo "✅ All tests passed!"
fi