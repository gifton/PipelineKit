# PipelineKit Performance Testing

## Overview

PipelineKit includes comprehensive performance tests using XCTest's built-in performance testing framework. These tests help ensure that performance doesn't regress and identify optimization opportunities.

## Architecture

Performance tests are located in the `Tests/PipelineKitPerformanceTests` target and use XCTest's `measure` API to capture performance metrics.

### Test Organization

- **PipelinePerformanceTests**: Core pipeline execution benchmarks
- **CommandContextPerformanceTests**: Context metadata operation benchmarks  
- **BackPressurePerformanceTests**: Concurrency control and semaphore benchmarks
- **PerformanceTestConfiguration**: Shared configuration for CI-aware test settings

## Running Performance Tests

### Quick Test Run

Run all performance tests:

```bash
swift test --filter PerformanceTests
```

### Release Mode (Recommended)

For accurate performance metrics, run in release mode:

```bash
swift test -c release --filter PerformanceTests
```

### Specific Test Categories

```bash
# Run only pipeline performance tests
swift test --filter PipelinePerformanceTests

# Run only BackPressure tests
swift test --filter BackPressurePerformanceTests

# Run a specific test
swift test --filter testSimplePipelineExecutionPerformance
```

### CI Mode

Use the CI-optimized script for automated testing:

```bash
./Scripts/run-performance-tests-ci.sh
```

### Full Performance Suite

Use the comprehensive script with baseline support:

```bash
./Scripts/run-performance-tests.sh [options]

Options:
  --debug              Run tests in debug configuration (default: release)
  --filter <pattern>   Filter tests by name pattern
  --baseline <name>    Name for baseline comparison
  --compare            Compare against baseline
  --update-baseline    Update the baseline with current results
  --help               Show help message
```

## Available Performance Tests

### Pipeline Performance

- **testSimplePipelineExecutionPerformance**: Baseline pipeline execution without middleware
- **testPipelineWithSingleMiddlewarePerformance**: Pipeline with one middleware component
- **testPipelineWithMultipleMiddlewarePerformance**: Pipeline with multiple middleware (5 components)
- **testConcurrentPipelineExecutionPerformance**: Concurrent pipeline execution (1000 operations)

### CommandContext Performance

- **testSetMetadataPerformance**: Metadata write operations (10,000 operations)
- **testGetMetadataPerformance**: Metadata read operations (10,000 reads)
- **testMixedMetadataOperationsPerformance**: Mixed read/write operations
- **testConcurrentMetadataAccessPerformance**: Concurrent access patterns
- **testContextCreationPerformance**: Context initialization overhead
- **testLargeContextPerformance**: Performance with large metadata sets

### BackPressure Performance

- **testUncontendedAcquirePerformance**: Fast path acquisition without contention
- **testTryAcquirePerformance**: Non-blocking acquisition attempts
- **testContendedAccessPerformance**: Performance under contention
- **testHighConcurrencyPerformance**: High concurrency scenarios (1000 concurrent tasks)
- **testFailedAcquirePerformance**: Failed acquisition attempts
- **testMemoryPressureWithManyTokens**: Memory usage with many tokens

## Metrics Captured

XCTest performance tests capture the following metrics:

- **XCTClockMetric**: Wall clock time
- **XCTCPUMetric**: CPU usage and cycles
- **XCTMemoryMetric**: Memory allocations and peak usage
- **XCTStorageMetric**: Disk I/O operations

## CI Integration

Performance tests are automatically adjusted for CI environments:

- Reduced iteration counts for faster execution
- Adjusted timeouts for reliability
- Streamlined metrics collection
- Environment detection via `CI` environment variable

## Performance Guidelines

### Writing New Performance Tests

1. Extend `XCTestCase` or `PerformanceTestCase` for shared configuration
2. Use `measure` with appropriate metrics:
   ```swift
   measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
       // Performance-critical code here
   }
   ```
3. Use expectations for async operations
4. Consider CI vs local environment differences

### Best Practices

- Run performance tests in release mode for accurate metrics
- Use consistent operation counts for comparable results
- Warm up caches before measuring when appropriate
- Isolate the code being measured
- Account for system variability with multiple iterations

## Interpreting Results

XCTest provides detailed performance metrics in the test output:

- **Average**: Mean execution time across iterations
- **Relative Standard Deviation**: Consistency of measurements
- **Maximum**: Worst-case performance
- **Minimum**: Best-case performance

Results can be viewed in:
- Terminal output when running tests
- Xcode's Report Navigator for detailed analysis
- CI logs for automated testing

## Baseline Comparisons

While XCTest supports baseline comparisons in Xcode, for CI environments we rely on:

1. Consistent test environments
2. Statistical analysis of results
3. Tracking metrics over time in CI dashboards

## Troubleshooting

### Tests Running Slowly

- Ensure you're running in release mode: `-c release`
- Check if `CI` environment variable is set for reduced iterations
- Verify system isn't under heavy load

### Inconsistent Results

- Increase iteration count for more stable averages
- Close other applications to reduce system noise
- Use `PerformanceTestConfiguration` for consistent settings

### Memory Issues

- Monitor with XCTMemoryMetric
- Check for retain cycles in test setup
- Ensure proper cleanup in test teardown