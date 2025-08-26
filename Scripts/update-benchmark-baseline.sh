#!/bin/bash

# update-benchmark-baseline.sh
# Updates the benchmark baseline for a specific branch
# Usage: ./update-benchmark-baseline.sh [branch_name]

set -euo pipefail

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
BRANCH="${1:-main}"
BENCHMARKS_DIR=".benchmarks"
BASELINE_FILE="${BENCHMARKS_DIR}/baseline-${BRANCH}.txt"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BENCHMARKS_DIR}/baseline-${BRANCH}-${TIMESTAMP}.txt"

echo "================================================"
echo "Benchmark Baseline Update"
echo "================================================"
echo "Branch: $BRANCH"
echo "Baseline: $BASELINE_FILE"
echo "================================================"
echo ""

# Create benchmarks directory if it doesn't exist
mkdir -p "$BENCHMARKS_DIR"

# Check if we're in the project root
if [[ ! -f "Package.swift" ]]; then
    echo -e "${RED}Error: Not in PipelineKit root directory${NC}"
    echo "Please run this script from the project root"
    exit 1
fi

# Run benchmarks
echo -e "${YELLOW}Running benchmarks...${NC}"
echo "This may take several minutes."
echo ""

# Run benchmarks and save output
if swift package --allow-writing-to-package-directory benchmark \
    --format text \
    --path benchmark-results-temp.txt; then
    echo -e "${GREEN}✅ Benchmarks completed successfully${NC}"
else
    echo -e "${RED}❌ Benchmark execution failed${NC}"
    exit 1
fi

# Backup existing baseline if it exists
if [[ -f "$BASELINE_FILE" ]]; then
    echo ""
    echo -e "${YELLOW}Backing up existing baseline...${NC}"
    cp "$BASELINE_FILE" "$BACKUP_FILE"
    echo "Backup saved to: $BACKUP_FILE"
    
    # Show comparison with old baseline
    echo ""
    echo "Comparing with previous baseline:"
    echo "-----------------------------"
    if ./Scripts/check-benchmark-regression.sh "$BASELINE_FILE" "benchmark-results-temp.txt" 30; then
        echo -e "${GREEN}No significant regressions detected${NC}"
    else
        echo -e "${YELLOW}Note: Some changes detected (see above)${NC}"
    fi
fi

# Update baseline
echo ""
echo -e "${YELLOW}Updating baseline...${NC}"
mv benchmark-results-temp.txt "$BASELINE_FILE"

# Show summary
echo ""
echo -e "${GREEN}✅ Baseline updated successfully!${NC}"
echo "File: $BASELINE_FILE"
echo ""
echo "To commit this baseline:"
echo "  git add $BASELINE_FILE"
echo "  git commit -m \"Update benchmark baseline for $BRANCH branch\""
echo ""
echo "To compare future runs against this baseline:"
echo "  ./Scripts/check-benchmark-regression.sh $BASELINE_FILE <new_results.txt>"