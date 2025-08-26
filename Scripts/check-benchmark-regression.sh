#!/bin/bash

# check-benchmark-regression.sh
# Compares benchmark results against a baseline and detects regressions
# Usage: ./check-benchmark-regression.sh <baseline_file> <current_file> [threshold_percent]

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Arguments
BASELINE_FILE="${1:-}"
CURRENT_FILE="${2:-}"
THRESHOLD="${3:-30}"  # Default 30% regression threshold

# Validate arguments
if [[ -z "$BASELINE_FILE" || -z "$CURRENT_FILE" ]]; then
    echo "Usage: $0 <baseline_file> <current_file> [threshold_percent]"
    echo "  baseline_file: Path to baseline benchmark results"
    echo "  current_file: Path to current benchmark results"
    echo "  threshold_percent: Regression threshold (default: 30%)"
    exit 1
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
    echo -e "${RED}Error: Baseline file not found: $BASELINE_FILE${NC}"
    exit 1
fi

if [[ ! -f "$CURRENT_FILE" ]]; then
    echo -e "${RED}Error: Current results file not found: $CURRENT_FILE${NC}"
    exit 1
fi

echo "================================================"
echo "Benchmark Regression Analysis"
echo "================================================"
echo "Baseline: $BASELINE_FILE"
echo "Current:  $CURRENT_FILE"
echo "Threshold: ${THRESHOLD}% regression tolerance"
echo "================================================"
echo ""

# Track overall status
FAILED=0
TOTAL_BENCHMARKS=0
REGRESSIONS=0
IMPROVEMENTS=0
WITHIN_THRESHOLD=0
NEW_BENCHMARKS=0

# Function to convert time to microseconds
convert_to_microseconds() {
    local value="$1"
    local unit="$2"
    
    case "$unit" in
        "ns")
            echo "scale=3; $value / 1000" | bc -l
            ;;
        "μs"|"us")
            echo "$value"
            ;;
        "ms")
            echo "scale=3; $value * 1000" | bc -l
            ;;
        "s")
            echo "scale=3; $value * 1000000" | bc -l
            ;;
        *)
            echo "$value"
            ;;
    esac
}

# Parse and compare benchmarks
echo "Individual Benchmark Results:"
echo "-----------------------------"

# Read current results and compare with baseline
while IFS= read -r line; do
    # Parse benchmark result lines
    # Expected formats:
    # - "BenchmarkName: X.Xμs avg, Y ops/sec"
    # - "BenchmarkName: X.Xms avg, Y.YK ops/sec"
    # - "BenchmarkName: X.Xns avg, Y.YM ops/sec"
    
    if [[ $line =~ ^([A-Za-z][A-Za-z0-9._-]+):\ ([0-9.]+)(ns|μs|us|ms|s)\ avg ]]; then
        BENCH_NAME="${BASH_REMATCH[1]}"
        CURRENT_TIME="${BASH_REMATCH[2]}"
        CURRENT_UNIT="${BASH_REMATCH[3]}"
        
        TOTAL_BENCHMARKS=$((TOTAL_BENCHMARKS + 1))
        
        # Convert to microseconds for uniform comparison
        CURRENT_TIME_US=$(convert_to_microseconds "$CURRENT_TIME" "$CURRENT_UNIT")
        
        # Find baseline time
        BASELINE_LINE=$(grep "^$BENCH_NAME:" "$BASELINE_FILE" 2>/dev/null || echo "")
        
        if [[ -z "$BASELINE_LINE" ]]; then
            echo -e "${YELLOW}⚠️  NEW: $BENCH_NAME - ${CURRENT_TIME}${CURRENT_UNIT} (no baseline)${NC}"
            NEW_BENCHMARKS=$((NEW_BENCHMARKS + 1))
        elif [[ $BASELINE_LINE =~ ([0-9.]+)(ns|μs|us|ms|s)\ avg ]]; then
            BASELINE_TIME="${BASH_REMATCH[1]}"
            BASELINE_UNIT="${BASH_REMATCH[2]}"
            
            # Convert baseline to microseconds
            BASELINE_TIME_US=$(convert_to_microseconds "$BASELINE_TIME" "$BASELINE_UNIT")
            
            # Calculate percentage change
            if (( $(echo "$BASELINE_TIME_US > 0" | bc -l) )); then
                CHANGE=$(echo "scale=2; (($CURRENT_TIME_US - $BASELINE_TIME_US) / $BASELINE_TIME_US) * 100" | bc -l)
                
                # Format change for display
                if (( $(echo "$CHANGE > 0" | bc -l) )); then
                    CHANGE_DISPLAY="+${CHANGE}%"
                else
                    CHANGE_DISPLAY="${CHANGE}%"
                fi
                
                # Determine status based on change
                if (( $(echo "$CHANGE > $THRESHOLD" | bc -l) )); then
                    # Regression detected
                    echo -e "${RED}❌ REGRESSION: $BENCH_NAME${NC}"
                    echo -e "   Baseline: ${BASELINE_TIME}${BASELINE_UNIT} → Current: ${CURRENT_TIME}${CURRENT_UNIT} (${CHANGE_DISPLAY})"
                    REGRESSIONS=$((REGRESSIONS + 1))
                    FAILED=1
                elif (( $(echo "$CHANGE < -10" | bc -l) )); then
                    # Significant improvement (>10% faster)
                    echo -e "${GREEN}✅ IMPROVED: $BENCH_NAME${NC}"
                    echo -e "   Baseline: ${BASELINE_TIME}${BASELINE_UNIT} → Current: ${CURRENT_TIME}${CURRENT_UNIT} (${CHANGE_DISPLAY})"
                    IMPROVEMENTS=$((IMPROVEMENTS + 1))
                else
                    # Within acceptable range
                    echo "✓ OK: $BENCH_NAME - ${CURRENT_TIME}${CURRENT_UNIT} (${CHANGE_DISPLAY})"
                    WITHIN_THRESHOLD=$((WITHIN_THRESHOLD + 1))
                fi
            else
                echo -e "${YELLOW}⚠️  SKIP: $BENCH_NAME - Invalid baseline value${NC}"
            fi
        fi
    fi
done < "$CURRENT_FILE"

# Print summary
echo ""
echo "================================================"
echo "Summary"
echo "================================================"
echo "Total benchmarks:    $TOTAL_BENCHMARKS"
echo -e "${GREEN}Improvements:        $IMPROVEMENTS${NC}"
echo "Within threshold:    $WITHIN_THRESHOLD"
echo -e "${YELLOW}New benchmarks:      $NEW_BENCHMARKS${NC}"
echo -e "${RED}Regressions:         $REGRESSIONS${NC}"
echo "================================================"

# Exit with appropriate code
if [ $FAILED -eq 1 ]; then
    echo ""
    echo -e "${RED}❌ Benchmark regression detected!${NC}"
    echo "One or more benchmarks exceeded the ${THRESHOLD}% regression threshold."
    exit 1
else
    echo ""
    echo -e "${GREEN}✅ All benchmarks within acceptable range${NC}"
    exit 0
fi