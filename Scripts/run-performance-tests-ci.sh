#!/bin/bash

# CI-optimized script for running PipelineKit performance tests
# This script runs quickly in CI with reduced iterations

set -e

# Colors for output (work in CI logs too)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}     PipelineKit Performance Tests (CI)${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Build in release mode for accurate performance metrics
echo -e "${YELLOW}Building performance tests in release mode...${NC}"
swift build -c release --target PipelineKitPerformanceTests

# Run the tests
echo -e "${YELLOW}Running performance tests...${NC}"
swift test -c release --filter "PerformanceTests" --parallel || {
    EXIT_CODE=$?
    echo -e "${RED}Performance tests failed with exit code: $EXIT_CODE${NC}"
    exit $EXIT_CODE
}

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}   Performance tests completed successfully!${NC}"
echo -e "${GREEN}================================================${NC}"