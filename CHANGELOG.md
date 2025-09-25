# Changelog

All notable changes to PipelineKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-09-08

### Added
- Swift 6.0 support with full strict concurrency compliance
- `AnySendable` wrapper for type-erased Sendable storage
- `ContextKey<T>` for type-safe CommandContext access
- Unified actor-based object pool design with `ObjectPool<T: Sendable>`
- `ReferenceObjectPool` wrapper with memory pressure handling
- `PooledObject` RAII wrapper for automatic pool return
- Core event emission system with `EventEmitter` protocol in PipelineKitCore
- Unified event emission between Core and Observability modules
- `EventHub` for centralized event routing
- `MetricsEventBridge` for automatic event-to-metric conversion
- `ObservabilitySystem` for complete observability integration
- Monotonic sequence IDs for `PipelineEvent` using atomic operations
- Comprehensive test support with `PipelineKitTestSupport` module

### Changed
- Migrated to Swift 6.0 minimum requirement
- Upgraded platform requirements (iOS 17, macOS 14, tvOS 17, watchOS 10)
- Refactored `CommandContext` to use `OSAllocatedUnfairLock` with type-safe keys
- Updated `Command` protocol to require Sendable conformance
- Consolidated object pool implementations into unified design
- Improved `SimpleSemaphore` to properly handle task cancellation with `CancellationError`
- Enhanced CI/CD pipeline with improved coverage reporting for macOS
- Fixed Linux compatibility by wrapping Compression framework code with platform checks
- Improved test reliability by adjusting timeout tolerances for CI environments

### Fixed
- Fixed PooledObject automatic return issue - deinit cannot call async actor methods
- Fixed critical bug in `SimpleSemaphore` where cancelled tasks would hang indefinitely
- Fixed continuation not being resumed on cancellation in semaphore implementations
- Fixed CI coverage report generation on macOS using `xcrun --find llvm-cov`
- Fixed Linux build failures with Compression framework dependencies
- Fixed all 74 SwiftLint violations for code quality
- Fixed compilation errors from automated SwiftLint corrections
- Removed invalid test file `DynamicPipelineRegistrationTests.swift` testing non-existent APIs

### Removed
- Removed `GenericObjectPool` (replaced by `ObjectPool`)
- Removed `NonSendableObjectPool` (use `ObjectPool` with Sendable types)
- Removed deprecated CommandContext methods
- Removed confusing stub implementations in Core's event emission

### Security
- Ensured all semaphore continuations are properly resumed to prevent resource leaks
- Added proper task cancellation handling throughout concurrency primitives

## [1.0.0] - 2025-09-25

### Breaking
- Renamed metadata initialisms for clarity and Swift guidelines compliance:
  - `CommandMetadata.userId` → `userID`
  - `CommandMetadata.correlationId` → `correlationID`
  - `PipelineError.ErrorContext.userId` → `userID`
  - `PipelineError.ErrorContext.correlationId` → `correlationID`
- `CommandContext.snapshot()`/`snapshotRaw()` keys now use `userID`/`correlationID`.
- Removed unused `associatedtype Metadata` from `Command` protocol.

### Added
- `DynamicPipeline.execute(_:context:retryPolicy:)` alias method (for parity with `Pipeline`).
- `PipelineBuilder` action‑style aliases (all forward to existing methods):
  - `addMiddleware(_:)`, `addMiddlewares(_:)`, `setMaxDepth(_:)`, `enableOptimization()`
  - `addAuthentication(_:)`, `addAuthorization(_:)`, `addRateLimiting(_:)`, `addLogging(_:)`
- `BackPressureSemaphore.stats` (alias for `getStats()`).
- `AsyncSemaphore.availableResources` (alias for `availableResourcesCount()`).

### Changed
- Made `PoolRegistry` static configuration concurrency‑safe using atomics:
  - `metricsEnabledByDefault`, `intelligentShrinkingEnabled`
  - `cleanupInterval`, `minimumShrinkInterval` (stored as atomic seconds)
- Updated docs and examples to reflect new aliases and initialisms; removed outdated content.

### Stability
- Marked small, stable value types as `@frozen`:
  - `DefaultCommandMetadata`, `HealthCheckResult`, `SemaphoreStats`, `SemaphoreHealth`.

### Migration Notes
- Update references from `userId`/`correlationId` to `userID`/`correlationID`.
- Remove any `typealias Metadata = ...` from `Command` types (no longer supported).
- All alias APIs are additive and source‑compatible.

## [Unreleased]

[Unreleased]: https://github.com/gifton/PipelineKit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/gifton/PipelineKit/releases/tag/v1.0.0
[0.1.0]: https://github.com/gifton/PipelineKit/releases/tag/v0.1.0
