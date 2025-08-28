#!/bin/bash

# Script to run PipelineKit performance tests

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CONFIGURATION="release"
FILTER="PipelineKitPerformanceTests"
BASELINE_NAME=""
COMPARE_BASELINE=false
UPDATE_BASELINE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            CONFIGURATION="debug"
            shift
            ;;
        --filter)
            FILTER="$2"
            shift 2
            ;;
        --baseline)
            BASELINE_NAME="$2"
            shift 2
            ;;
        --compare)
            COMPARE_BASELINE=true
            shift
            ;;
        --update-baseline)
            UPDATE_BASELINE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --debug              Run tests in debug configuration (default: release)"
            echo "  --filter <pattern>   Filter tests by name pattern"
            echo "  --baseline <name>    Name for baseline comparison"
            echo "  --compare            Compare against baseline"
            echo "  --update-baseline    Update the baseline with current results"
            echo "  --help               Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Header
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}     PipelineKit Performance Test Suite${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Check if we're in CI
if [ "$CI" == "true" ]; then
    echo -e "${YELLOW}Running in CI mode - reduced iterations${NC}"
fi

# Build configuration info
echo -e "${GREEN}Configuration:${NC} $CONFIGURATION"
echo -e "${GREEN}Test Filter:${NC} $FILTER"

if [ ! -z "$BASELINE_NAME" ]; then
    echo -e "${GREEN}Baseline:${NC} $BASELINE_NAME"
fi

echo ""

# Build tests
echo -e "${YELLOW}Building tests...${NC}"
swift build -c $CONFIGURATION --target PipelineKitPerformanceTests

# Prepare xcodebuild arguments
if [ "$CONFIGURATION" = "debug" ]; then
    CONFIG_NAME="Debug"
else
    CONFIG_NAME="Release"
fi

XCODEBUILD_ARGS=(
    -scheme PipelineKit
    -configuration "$CONFIG_NAME"
    -enableCodeCoverage NO
    test
)

# Add filter if specified
if [ "$FILTER" != "PipelineKitPerformanceTests" ]; then
    XCODEBUILD_ARGS+=(-only-testing:$FILTER)
else
    XCODEBUILD_ARGS+=(-only-testing:PipelineKitPerformanceTests)
fi

# Add baseline options
if [ ! -z "$BASELINE_NAME" ]; then
    if [ "$UPDATE_BASELINE" == "true" ]; then
        XCODEBUILD_ARGS+=(-baseline:$BASELINE_NAME -baselineAverage)
    elif [ "$COMPARE_BASELINE" == "true" ]; then
        XCODEBUILD_ARGS+=(-baseline:$BASELINE_NAME)
    fi
fi

# Run performance tests using swift test
echo -e "${YELLOW}Running performance tests...${NC}"
echo ""

if [ "$CI" == "true" ]; then
    # In CI, use swift test with parallel execution
    swift test \
        -c $CONFIGURATION \
        --filter "$FILTER" \
        --parallel || {
        EXIT_CODE=$?
        echo -e "${RED}Performance tests failed with exit code: $EXIT_CODE${NC}"
        exit $EXIT_CODE
    }
else
    # Local development - full run
    swift test \
        -c $CONFIGURATION \
        --filter "$FILTER" \
        --parallel
fi

# Success
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Performance tests completed successfully!${NC}"
echo -e "${GREEN}================================================${NC}"

# If running locally, provide additional instructions
if [ "$CI" != "true" ]; then
    echo ""
    echo "To view detailed results in Xcode:"
    echo "  1. Open PipelineKit.xcodeproj"
    echo "  2. Go to Report Navigator (⌘9)"
    echo "  3. Select the latest test run"
    echo "  4. Click on individual tests to see performance metrics"
fi