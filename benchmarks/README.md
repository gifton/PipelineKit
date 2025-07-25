# PipelineKit Benchmarks

This directory contains various performance benchmarks for PipelineKit.

## Running Benchmarks

To run a benchmark, use the Swift compiler directly:

```bash
swift benchmarks/context-benchmark.swift
```

## Available Benchmarks

- `context-benchmark.swift` - Tests CommandContext performance
- `middleware-chain-benchmark.swift` - Tests middleware chain execution performance
- `fast-paths-benchmark.swift` - Tests optimized fast paths
- `realistic-context-benchmark.swift` - Tests realistic usage scenarios
- `combined-optimization-benchmark.swift` - Tests combined optimizations
- `swift6-performance-check.swift` - Swift 6 concurrency performance tests
- `test_basic_performance.swift` - Basic performance tests
- `test_optimizer_activation.swift` - Tests optimizer activation
- `test-phase2.swift` - Phase 2 performance tests

## Note

These benchmarks are not part of the main test suite and are intended for 
performance analysis during development.