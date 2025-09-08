#!/bin/bash

# Generate code coverage analysis for PipelineKit
# Usage: ./Scripts/analyze-coverage.sh

set -e

echo "=================================================="
echo "PipelineKit Code Coverage Analysis"
echo "=================================================="
echo

# Check if coverage data exists
if [ ! -f ".build/coverage.profdata" ]; then
    echo "Coverage data not found. Running tests with coverage..."
    swift test --enable-code-coverage
    
    echo "Merging coverage data..."
    xcrun llvm-profdata merge \
        .build/arm64-apple-macosx/debug/codecov/*.profraw \
        -o .build/coverage.profdata
fi

# Generate coverage report
echo "Generating coverage report..."
COVERAGE_OUTPUT=$(xcrun llvm-cov report \
    .build/arm64-apple-macosx/debug/PipelineKitPackageTests.xctest/Contents/MacOS/PipelineKitPackageTests \
    -instr-profile=.build/coverage.profdata \
    -ignore-filename-regex=".build|Tests" 2>&1)

echo
echo "=================================================="
echo "OVERALL PROJECT COVERAGE:"
echo "=================================================="
echo "$COVERAGE_OUTPUT" | grep "^TOTAL" | awk '{
    printf "Line Coverage:     %.1f%% (%d/%d lines)\n", 100*($2-$3)/$2, $2-$3, $2
    printf "Function Coverage: %.1f%% (%d/%d functions)\n", 100*($5-$6)/$5, $5-$6, $5
    printf "Region Coverage:   %.1f%% (%d/%d regions)\n", 100*($8-$9)/$8, $8-$9, $8
}'

echo
echo "=================================================="
echo "MODULE-LEVEL COVERAGE:"
echo "=================================================="

# Function to calculate module coverage
calculate_module_coverage() {
    local module=$1
    local stats=$(echo "$COVERAGE_OUTPUT" | grep "^$module/" | awk '{
        lines += $2
        uncovered += $3
        funcs += $5
        uncovered_funcs += $6
    } END {
        if (lines > 0) {
            line_cov = ((lines - uncovered) / lines) * 100
            func_cov = ((funcs - uncovered_funcs) / funcs) * 100
            printf "%.1f%% lines, %.1f%% functions", line_cov, func_cov
        } else {
            print "No data"
        }
    }')
    echo "$stats"
}

# Core modules
printf "%-35s %s\n" "PipelineKitCore:" "$(calculate_module_coverage PipelineKitCore)"
printf "%-35s %s\n" "PipelineKit:" "$(calculate_module_coverage PipelineKit)"
printf "%-35s %s\n" "PipelineKitObservability:" "$(calculate_module_coverage PipelineKitObservability)"
printf "%-35s %s\n" "PipelineKitSecurity:" "$(calculate_module_coverage PipelineKitSecurity)"
printf "%-35s %s\n" "PipelineKitCache:" "$(calculate_module_coverage PipelineKitCache)"
printf "%-35s %s\n" "PipelineKitPooling:" "$(calculate_module_coverage PipelineKitPooling)"
printf "%-35s %s\n" "PipelineKitResilienceCore:" "$(calculate_module_coverage PipelineKitResilienceCore)"
printf "%-35s %s\n" "PipelineKitResilienceCircuitBreaker:" "$(calculate_module_coverage PipelineKitResilienceCircuitBreaker)"

echo
echo "=================================================="
echo "FILES WITH 100% LINE COVERAGE:"
echo "=================================================="
echo "$COVERAGE_OUTPUT" | grep -E "^PipelineKit.*\s+100\.00%" | awk '{print "✅", $1}' | head -20

echo
echo "=================================================="
echo "FILES WITH < 20% LINE COVERAGE:"
echo "=================================================="
echo "$COVERAGE_OUTPUT" | awk '$4 ~ /%$/ && $4+0 < 20 && $1 ~ /^PipelineKit/ {printf "⚠️  %-60s %s\n", $1, $4}' | head -20

echo
echo "Coverage analysis complete!"