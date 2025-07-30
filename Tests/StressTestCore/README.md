# Stress Test Framework Testing

This directory contains comprehensive tests for the PipelineKit Stress Testing Framework.

## Test Structure

```
Tests/
├── StressTestCore/          # Core stress test framework tests
│   ├── Unit/               # Unit tests for individual components
│   ├── Integration/        # Integration tests for component interactions
│   └── Utilities/          # Test utilities and helpers
└── StressTestTSan/         # Thread Sanitizer validation tests
```

## Running Tests

### All Tests
```bash
./Scripts/run-stress-tests.sh
```

### Core Tests Only
```bash
swift test --filter StressTestCore
```

### TSan Tests Only
```bash
export TSAN_OPTIONS="suppressions=$(pwd)/tsan.suppressions"
swift test --configuration debug --filter StressTestTSan --sanitize thread
```

## Test Utilities

### TestMetricCollector
Mock implementation of MetricCollector for capturing and validating metrics:
- Records all metrics, events, gauges, and counters
- Provides assertion helpers for test validation
- Supports metric filtering and analysis

### MockSafetyMonitor
Controllable SafetyMonitor for testing safety enforcement:
- Configure resource usage and violation triggers
- Track all monitor interactions
- Simulate various safety scenarios

### TestHelpers
Common test utilities and extensions:
- Scenario execution helpers
- Async test utilities
- Metric validation helpers

## Thread Sanitizer (TSan)

TSan helps detect data races in concurrent code. The framework includes:

1. **TSan Configuration** in Package.swift
2. **Suppression File** (`tsan.suppressions`) for known benign races
3. **Validation Tests** to ensure TSan is working correctly

### TSan Suppressions

The suppression file includes:
- Swift runtime benign races
- System library known issues
- Actor initialization patterns
- Test framework internals

Each suppression should be documented with:
- Why the race is benign
- Reference to documentation
- Review date

## Test Coverage

### Unit Tests
- CPU Load Simulator patterns
- Memory Pressure Simulator operations
- Concurrency Stressor scenarios
- Resource Exhauster reliability
- Safety Monitor thresholds
- Metric Collector accuracy

### Integration Tests
- Orchestrator + Simulator lifecycle
- Safety enforcement flow
- Concurrent simulation execution
- Resource cleanup verification
- Metric flow validation

### Scenario Tests
- BurstLoad scenario execution
- SustainedLoad stability
- Chaos determinism
- RampUp progression

## Writing New Tests

1. **Create Test File** in appropriate directory
2. **Import Test Utilities**:
   ```swift
   import XCTest
   @testable import PipelineKit
   ```

3. **Use Test Helpers**:
   ```swift
   let collector = TestMetricCollector()
   let monitor = MockSafetyMonitor()
   ```

4. **Write Assertions**:
   ```swift
   await collector.assertMetricRecorded(name: "stress.cpu.load", type: .gauge)
   await monitor.assertStatusChecked(count: 5)
   ```

## Debugging Test Failures

### TSan Reports
If TSan reports a race:
1. Check if it's a known benign race
2. Add to suppressions if benign
3. Fix the race if real

### Flaky Tests
For intermittent failures:
1. Add more detailed logging
2. Increase timeouts for async operations
3. Check for race conditions
4. Verify cleanup between tests

### Performance Issues
If tests are slow:
1. Reduce simulation durations in tests
2. Use smaller data sets
3. Run tests in parallel when possible
4. Profile with Instruments