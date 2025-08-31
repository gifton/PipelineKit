# NextGuard Configuration Guide

## Overview

NextGuard is a safety mechanism that ensures middleware calls `next()` exactly once. By default, it emits warnings when this contract is violated. However, due to Swift's concurrency limitations with timeout scenarios, you may see false positives. This guide shows how to configure NextGuard warnings to suit your needs.

## Quick Start

### Recommended Default Configuration

```swift
// In your app initialization
import PipelineKit

// Suppress timeout-related false positives (recommended)
NextGuard.setWarningMode(.suppressTimeouts)
```

### Common Configurations

```swift
// Option 1: Disable all warnings (not recommended for development)
NextGuard.disableWarnings()

// Option 2: Enable all warnings (may show false positives)
NextGuard.setWarningMode(.all)

// Option 3: Custom configuration
NextGuard.setWarningMode(.custom(
    emitWarnings: true,
    suppressTimeouts: true
))

// Option 4: Integrate with your logging system
NextGuard.setWarningHandler { message in
    MyLogger.warning(message)
}
```

## Configuration Options

### Warning Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `.all` | Show all warnings | Debugging middleware issues |
| `.suppressTimeouts` | Hide timeout false positives | **Recommended default** |
| `.disabled` | No warnings | Production builds |
| `.custom(...)` | Fine-grained control | Advanced users |

### Environment Variables

You can also control warnings via environment variables:

```bash
# Disable all NextGuard warnings
PIPELINEKIT_DISABLE_NEXTGUARD_WARNINGS=1 swift run

# Useful for CI/CD
PIPELINEKIT_DISABLE_NEXTGUARD_WARNINGS=1 swift test
```

## Testing

### Temporary Suppression

For tests that intentionally violate the middleware contract:

```swift
func testTimeoutScenario() async throws {
    // Suppress warnings for this test only
    await NextGuard.withoutWarnings {
        // Your test code that might trigger false positives
        try await testPipelineWithTimeout()
    }
}
```

### Test Suite Configuration

```swift
class MyTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Disable warnings for all tests in this suite
        NextGuard.setWarningMode(.disabled)
    }
    
    override class func tearDown() {
        // Reset to defaults
        NextGuard.resetConfiguration()
        super.tearDown()
    }
}
```

## Production vs Development

### Development Configuration

```swift
#if DEBUG
    // Show warnings but suppress known false positives
    NextGuard.setWarningMode(.suppressTimeouts)
#else
    // Disable in production to avoid log noise
    NextGuard.disableWarnings()
#endif
```

### Custom Logger Integration

```swift
NextGuard.setWarningHandler { message in
    #if DEBUG
        // In development, print to console
        print(message)
    #else
        // In production, send to monitoring service
        TelemetryService.logWarning(message, category: .middleware)
    #endif
}
```

## Understanding the Warnings

### Legitimate Warnings (Bugs to Fix)

```swift
class BrokenMiddleware: Middleware {
    func execute(...) async throws -> Result {
        // ❌ BUG: Forgot to call next()
        return someResult  // Will trigger warning
    }
}

class DoubleCallMiddleware: Middleware {
    func execute(...) async throws -> Result {
        let result1 = try await next(command, context)
        let result2 = try await next(command, context)  // ❌ BUG: Called twice
        return result1
    }
}
```

### False Positives (Safe to Ignore)

```swift
class TimeoutMiddleware: Middleware {
    func execute(...) async throws -> Result {
        try await withTimeout(5.0) {
            try await next(command, context)  // May not complete if timeout occurs
        }
        // ⚠️ False positive: NextGuard may warn if timeout occurs
        // This is safe - the timeout legitimately prevented next() from completing
    }
}
```

## Why False Positives Occur

Due to Swift's actor isolation model, NextGuard's `deinit` (which is synchronous) cannot reliably detect if a timeout occurred. The warning system uses heuristics that may not catch all timeout scenarios. See [NEXTGUARD_TIMEOUT_LIMITATION.md](./NEXTGUARD_TIMEOUT_LIMITATION.md) for technical details.

## Best Practices

1. **Use `.suppressTimeouts` mode by default** - Eliminates most false positives while catching real bugs

2. **Don't disable warnings entirely in development** - They catch real middleware bugs

3. **Configure once at app startup** - Avoid changing configuration during runtime

4. **Use environment variables for CI** - Prevents test failures from false positives

5. **Monitor in production** - If you keep warnings enabled, monitor the frequency to detect issues

## Migration Guide

If you're seeing false positive warnings:

```swift
// Before: Annoying false positives
// ⚠️ WARNING: NextGuard(TimeoutMiddleware) deallocated without calling next()

// After: Clean logs
NextGuard.setWarningMode(.suppressTimeouts)
// No more false positives for timeout scenarios!
```

## Troubleshooting

### Still Seeing Warnings?

1. Ensure configuration is set before creating pipelines
2. Check that middleware identifiers contain "Timeout" or "Slow" for heuristic detection
3. Consider using `.disabled` mode if warnings persist

### Need More Control?

```swift
// Implement custom logic
NextGuard.setWarningHandler { message in
    // Filter based on your criteria
    if !message.contains("MyCustomMiddleware") {
        Logger.warning(message)
    }
}
```

## Summary

- **Default**: Use `.suppressTimeouts` mode
- **Testing**: Use `withoutWarnings` for specific tests
- **Production**: Consider disabling warnings entirely
- **Custom**: Integrate with your logging system

This configuration system gives you full control over NextGuard's behavior while maintaining its safety benefits.