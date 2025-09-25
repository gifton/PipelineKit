# NextGuard Configuration Guide

## Overview

NextGuard ensures middleware calls `next()` exactly once. Runtime safety is enforced (multiple or concurrent `next` calls throw). In debug builds, a deinit‑time warning is emitted if `next()` was never called. This document describes global warning configuration and per‑middleware suppression for intentional short‑circuits.

## Quick Start

### Recommended Defaults

```swift
import PipelineKit

// Enable warnings globally
NextGuardConfiguration.shared.emitWarnings = true

// Route warnings to your logging system
NextGuardConfiguration.setWarningHandler { message in
    myLogger.warning("[NextGuard] \(message)")
}
```

### Intentional Short‑Circuiting

If a middleware intentionally short‑circuits without calling `next()` (e.g., cache hit), conform to `NextGuardWarningSuppressing` to suppress debug‑only deinit warnings for that middleware:

```swift
struct MyCachingMiddleware: Middleware, NextGuardWarningSuppressing {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if let cached = await lookup(command) {
            return cached // Intentional short‑circuit; no deinit warning in DEBUG
        }
        return try await next(command, context)
    }
}
```

## Configuration Options

### Global Warning Controls

- `NextGuardConfiguration.shared.emitWarnings: Bool` – enable/disable warnings
- `NextGuardConfiguration.setWarningHandler(_:)` – integrate with your logging system

### Test Environments

In CI or tests, you can route warnings to a no‑op handler to silence output without changing runtime behavior:

```swift
NextGuardConfiguration.setWarningHandler { _ in /* no‑op in CI */ }
```

## Best Practices

1. Keep warnings enabled in development; they catch real middleware bugs.
2. Use `NextGuardWarningSuppressing` for legitimate short‑circuits (e.g., caching, deduplication paths).
3. Configure warning handler at app startup; avoid flipping settings during runtime.
4. In CI, you can silence warnings by setting a no‑op handler.

## Notes

- Deinit warnings are DEBUG‑only diagnostics; runtime correctness is enforced regardless of configuration.
- Timeout‑based heuristics have been removed in favor of explicit, per‑middleware suppression.
