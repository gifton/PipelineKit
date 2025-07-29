# PipelineKit Benchmark Suite

A comprehensive performance benchmarking framework for PipelineKit following Swift ecosystem standards.

## Overview

This benchmark suite provides:
- Standardized benchmark protocols
- Statistical analysis with outlier detection
- Memory usage tracking
- Regression detection
- CI/CD integration support
- Baseline comparison

## Running Benchmarks

### Build and run all benchmarks:
```bash
swift run PipelineKitBenchmarks
```

### Quick mode (fewer iterations):
```bash
swift run PipelineKitBenchmarks --quick
```

### Run specific benchmark:
```bash
swift run PipelineKitBenchmarks --benchmark "CommandContext"
```

### Save baseline for comparison:
```bash
swift run PipelineKitBenchmarks --save-baseline
```

### Compare with baseline:
```bash
swift run PipelineKitBenchmarks --compare-baseline
```

## Writing Benchmarks

### Simple Benchmark

```swift
struct MyBenchmark: Benchmark {
    let name = "My Performance Test"
    let iterations = 1000
    let warmupIterations = 100
    
    func run() async throws {
        // Code to benchmark
    }
}
```

### Parameterized Benchmark

```swift
struct MyParameterizedBenchmark: ParameterizedBenchmark {
    let name = "Parameterized Test"
    typealias Input = TestData
    
    func makeInput() async throws -> TestData {
        // Generate test data
    }
    
    func run(input: TestData) async throws {
        // Code to benchmark with input
    }
}
```

## Architecture

### Core Components

- **Benchmark Protocol**: Defines the interface for all benchmarks
- **BenchmarkRunner**: Executes benchmarks and collects measurements
- **Statistics**: Calculates mean, median, percentiles, and detects outliers
- **MemoryTracking**: Monitors memory usage and allocations
- **BenchmarkComparison**: Detects performance regressions

### Directory Structure

```
Sources/PipelineKitBenchmarks/
├── Core/
│   ├── Benchmark.swift         # Protocol definitions
│   ├── BenchmarkRunner.swift   # Execution engine
│   └── Measurement.swift       # Result types
├── Utilities/
│   ├── Statistics.swift        # Statistical analysis
│   └── MemoryTracking.swift    # Memory monitoring
├── Benchmarks/
│   ├── CommandContextBenchmark.swift
│   ├── PipelineBenchmark.swift
│   └── MiddlewareBenchmark.swift
└── main.swift                  # CLI entry point
```

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Performance Tests
on: [pull_request]

jobs:
  benchmark:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Benchmarks
        run: swift run PipelineKitBenchmarks --save-baseline
      - name: Compare with Base
        run: |
          git checkout main
          swift run PipelineKitBenchmarks --compare-baseline
```

## Statistical Analysis

The framework provides comprehensive statistical analysis:

- **Mean & Median**: Central tendency measures
- **Standard Deviation**: Variability measure
- **Percentiles**: P95 and P99 for tail latency
- **Outlier Detection**: IQR-based outlier removal
- **Stability Check**: Coefficient of variation < 5%

## Regression Detection

Automatic regression detection using:
- Student's t-test for statistical significance
- Configurable threshold (default: 5%)
- Detailed comparison reports
- CI/CD integration for PR blocking

## Best Practices

1. **Warm-up Phase**: Always include warm-up iterations
2. **Sufficient Samples**: Use at least 1000 iterations for stable results
3. **Isolated Environment**: Run benchmarks on quiet systems
4. **Memory Tracking**: Enable for memory-sensitive code
5. **Baseline Management**: Regularly update baselines

## Troubleshooting

### High Variance
- Increase iteration count
- Check for system load
- Use `--quiet` mode
- Consider outlier impact

### Memory Tracking Issues
- Ensure macOS/iOS platform
- Check for memory pressure
- Verify pool statistics

### Regression False Positives
- Verify baseline is recent
- Check platform differences
- Review statistical significance