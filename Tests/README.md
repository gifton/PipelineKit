# PipelineKit Test Suite

## Overview

The PipelineKit test suite contains **510+ test methods** across **65 test files**, organized into modular test targets that mirror the library structure.

## Test Organization

```
Tests/
├── PipelineKitCoreTests/        # Core functionality (32 tests)
├── PipelineKitResilienceTests/  # Resilience patterns (104 tests)
├── PipelineKitSecurityTests/    # Security features (93 tests)
├── PipelineKitObservabilityTests/ # Metrics & events (86 tests)
├── PipelineKitCacheTests/       # Caching middleware (10 tests)
├── PipelineKitPoolingTests/     # Object pooling (63 tests)
├── PipelineKitIntegrationTests/ # Integration tests (9 tests)
├── PipelineKitTests/            # Legacy tests (110 tests)
└── PipelineKitTestSupportTests/ # Test utilities (3 tests)
```

## Running Tests

### Quick Start

```bash
# Run all tests
swift test

# Run specific module tests
swift test --filter PipelineKitCoreTests

# Run with parallel execution
swift test --parallel

# Use the test runner script
./Scripts/run-tests.sh
./Scripts/run-tests.sh --target PipelineKitCore
./Scripts/run-tests.sh --verbose
```

### Test Commands

The package includes custom test commands:

```bash
# Run unit tests
swift package test-unit

# Run stress tests
swift package test-stress

# Run integration tests
swift package test-integration
```

## Test Categories

### Unit Tests (~95%)
- Component isolation testing
- Mock-based testing
- Fast execution (<3 seconds)

### Integration Tests (~5%)
- Cross-module validation
- End-to-end workflows
- Real component interaction

### Performance Tests
- Benchmarking suite
- Stress testing with TSAN
- Concurrency validation

## Test Infrastructure

### PipelineKitTestSupport
Provides comprehensive test utilities:
- Thread-safe test actors
- Mock implementations
- Test command helpers
- Synchronization utilities

### Key Test Patterns

1. **Async Testing**
```swift
func testAsyncOperation() async throws {
    let result = await someAsyncOperation()
    XCTAssertEqual(result, expected)
}
```

2. **Thread Safety Testing**
```swift
func testConcurrentAccess() async throws {
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 {
            group.addTask { /* concurrent operation */ }
        }
    }
}
```

3. **Timeout Testing**
```swift
func testTimeout() async throws {
    let expectation = XCTestExpectation()
    // Test with timeout
}
```

## CI/CD Integration

Tests run automatically on:
- Push to main/develop branches
- Pull requests
- Nightly stress tests

Platforms:
- macOS 14 (primary)
- Ubuntu 22.04 (Linux compatibility)
- Swift 6.0

## Coverage

Current focus areas:
- [ ] PipelineKitCore - Foundation coverage
- [ ] PipelineKitSecurity - Security validation
- [ ] Integration tests - Cross-module testing
- [ ] Performance benchmarks - Regression detection

## Contributing

When adding tests:
1. Place tests in the appropriate module test target
2. Follow existing naming conventions
3. Include both success and failure cases
4. Add integration tests for cross-module features
5. Ensure tests are deterministic and isolated

## Troubleshooting

### Tests Not Running
- Check Swift version: `swift --version` (requires 6.0)
- Clean build: `swift package clean`
- Verify imports are correct

### Coverage Not Generating
- Use: `swift test --enable-code-coverage`
- Check `.build/*/debug/codecov/` for results

### Slow Tests
- Use `--parallel` flag
- Check for unnecessary delays in tests
- Profile with Instruments if needed