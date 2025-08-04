#!/bin/bash

echo "Running BackPressure benchmarks without TSAN..."
echo "================================================"

# Build only what we need
swift build --target PipelineKit --target PipelineKitTests

# Run specific benchmark tests
echo ""
echo "Running benchmark tests..."

# List of benchmark test methods
tests=(
    "testPriorityQueuePerformance"
    "testTryAcquirePerformance"
    "testCancellationPerformance"
    "testHighContentionScenario"
    "testUncontendedFastPath"
    "testMildContention"
    "testHeavyContention"
    "testPingPongFairness"
    "testMassCancellation"
    "testMemoryPressureSimulation"
)

# Run each test individually to avoid timeouts
for test in "${tests[@]}"; do
    echo ""
    echo "Running $test..."
    swift test --skip-build --filter "BackPressureBenchmarkTests/$test" 2>&1 | grep -A 20 "===" || echo "Test failed or timed out"
done

echo ""
echo "Benchmarks complete!"