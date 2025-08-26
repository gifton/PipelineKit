#!/bin/bash
# Simple test coverage script for PipelineKit

echo "=== PipelineKit Test Coverage Report ==="
echo "Date: $(date)"
echo ""

# Clean previous builds
echo "Cleaning previous builds..."
swift package clean

# Build with coverage
echo "Building with coverage enabled..."
swift build --enable-code-coverage

# Run tests with coverage
echo "Running tests with coverage..."
swift test --enable-code-coverage --parallel

# Find the coverage data
COVERAGE_DIR=".build/debug/codecov"
if [ -d ".build/arm64-apple-macosx/debug/codecov" ]; then
    COVERAGE_DIR=".build/arm64-apple-macosx/debug/codecov"
elif [ -d ".build/x86_64-apple-macosx/debug/codecov" ]; then
    COVERAGE_DIR=".build/x86_64-apple-macosx/debug/codecov"
fi

echo ""
echo "Coverage directory: $COVERAGE_DIR"

# Generate simple coverage report
if [ -d "$COVERAGE_DIR" ]; then
    echo ""
    echo "=== Coverage Summary ==="
    
    # Count test files
    TEST_COUNT=$(find Tests -name "*.swift" -type f | wc -l | tr -d ' ')
    echo "Test files: $TEST_COUNT"
    
    # Count source files
    SOURCE_COUNT=$(find Sources -name "*.swift" -type f | wc -l | tr -d ' ')
    echo "Source files: $SOURCE_COUNT"
    
    # Count test methods
    TEST_METHODS=$(grep -r "func test" Tests --include="*.swift" | wc -l | tr -d ' ')
    echo "Test methods: $TEST_METHODS"
    
    echo ""
    echo "Test execution complete."
else
    echo "Warning: Coverage data not found at $COVERAGE_DIR"
fi