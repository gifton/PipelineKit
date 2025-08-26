# PipelineKit Benchmarks

## Overview

PipelineKit includes a comprehensive benchmark suite to measure and track performance across different components. The benchmarks help ensure that performance doesn't regress and identify optimization opportunities.

## Running Benchmarks

### Quick Mode

Run benchmarks with fewer iterations for quick validation:

```bash
swift run PipelineKitBenchmarks --quick
```

### Full Mode

Run comprehensive benchmarks with more iterations:

```bash
swift run PipelineKitBenchmarks
```

### Specific Benchmarks

Run benchmarks matching a pattern:

```bash
# Run all BackPressure benchmarks
swift run PipelineKitBenchmarks BackPressure

# Run specific benchmark
swift run PipelineKitBenchmarks --benchmark BackPressure-Uncontended
```

### Help

View all available options:

```bash
swift run PipelineKitBenchmarks --help
```

## Available Benchmarks

### BackPressure Benchmarks

- **BackPressure-Uncontended**: Tests uncontended fast path performance
- **BackPressure-TryAcquire**: Tests tryAcquire performance
- **BackPressure-Contention**: Tests performance under contention (mild and heavy)
- **BackPressure-Cancellation**: Tests cancellation performance
- **BackPressure-Memory**: Tests memory pressure handling

### Core Benchmarks

- **CommandContext**: Tests CommandContext creation, storage, and forking
- **Pipeline**: Tests pipeline execution with and without middleware

## Benchmark Architecture

### Infrastructure

The benchmark suite uses a protocol-based architecture:

```swift
protocol Benchmark {
    var name: String { get }
    var description: String { get }
    func run() async throws
}
```

### BenchmarkRunner

The `BenchmarkRunner` class manages benchmark execution and result collection:

```swift
let runner = BenchmarkRunner()
runner.register(MyBenchmark())
try await runner.run(quick: true)
```

### Result Reporting

Results include:
- Duration
- Operations count
- Throughput (operations per second)
- Average latency

## Adding New Benchmarks

To add a new benchmark:

1. Create a struct conforming to the `Benchmark` protocol
2. Implement the required properties and `run()` method
3. Register it in `main.swift`

Example:

```swift
struct MyBenchmark: Benchmark {
    let name = "MyComponent"
    let description = "Tests MyComponent performance"
    
    func run() async throws {
        let runner = BenchmarkRunner()
        
        _ = try await runner.measure(name: "Operation", iterations: 10_000) {
            // Benchmark code here
        }
    }
}
```

## CI Integration

Benchmarks are automatically run in CI:

- On push to main branch
- On pull requests (quick mode)
- Daily scheduled runs (full mode)

See `.github/workflows/benchmarks.yml` for configuration.

## Performance Goals

### BackPressure
- Uncontended operations: < 1μs latency
- High throughput under contention
- Efficient cancellation handling
- Memory pressure correctly enforced

### CommandContext
- Context creation: < 100ns
- Value storage/retrieval: < 50ns per operation
- Fork operation: < 500ns

### Pipeline
- Empty pipeline overhead: < 100ns
- Per-middleware overhead: < 50ns

## Baseline Comparison

The benchmark suite supports baseline comparison to detect regressions:

```bash
# Save current results as baseline
swift run PipelineKitBenchmarks --save-baseline

# Compare against baseline
swift run PipelineKitBenchmarks --compare-baseline
```

Baselines are stored in `.benchmarks/` directory.

## Best Practices

1. **Warm-up**: Allow for warm-up iterations to stabilize performance
2. **Multiple Runs**: Run benchmarks multiple times to ensure consistency
3. **Isolation**: Run benchmarks on a quiet system without other heavy processes
4. **Release Mode**: Always benchmark in release configuration
5. **Statistical Analysis**: Use percentiles (p50, p90, p99) rather than just averages

## Troubleshooting

### High Variance

If benchmark results show high variance:
- Increase iteration count
- Ensure system is not under load
- Check for thermal throttling
- Disable CPU frequency scaling

### Unexpected Results

If benchmarks show unexpected performance:
- Verify release build configuration
- Check for debug assertions
- Profile with Instruments
- Review recent code changes

## Future Improvements

- [ ] Add memory allocation tracking
- [ ] Implement regression detection
- [ ] Add JSON/CSV export
- [ ] Create performance dashboard
- [ ] Add comparison visualization