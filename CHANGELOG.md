# Changelog

All notable changes to PipelineKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`ExecutionContext` task-local propagation**: `ExecutionContext.current` gives code
  below the handler — repositories, loggers, helpers at any depth — implicit access to
  immutable `TraceMetadata` (commandID/correlationID/userID) and an optional
  `ProgressReporter` capability, bound by `StandardPipeline` around the middleware
  chain + handler and by `DynamicPipeline` around its entire retry loop. Attach a
  reporter via
  `ContextKeys.progressReporter` and consume a bounded, lossy
  `AsyncStream<ProgressUpdate>`; the pipeline terminates it on completion or throw.
  `ExecutionContext.Snapshot` (Codable) + `withRestored(_:progress:)` define the
  rebind contract for future deferred execution. Purely additive; `current` is `nil`
  outside pipeline execution and in detached tasks.
- `CONTRIBUTING.md` (development setup, test workflow, PR conventions) and
  `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1).
- DocC catalog for the `PipelineKit` module (landing page + Getting Started,
  Architecture, Middleware Guide, ExecutionContext & Progress articles); combined
  DocC site publishing all seven public modules to GitHub Pages; per-PR
  documentation-coverage gate with per-target ratchet floors
  (`Scripts/check-doc-coverage.sh`).

### Changed
- **Nested pipeline executions inherit the enclosing execution's progress reporter**:
  when `StandardPipeline` or `DynamicPipeline` binds a `CommandContext` that attaches
  no `ProgressReporter`, `ExecutionContext.current?.progress` now resolves to the
  enclosing execution's reporter at any nesting depth, so inner executions report into
  the outer stream with no caller wiring. Ownership is unchanged: only the execution
  whose context attached the reporter finishes the stream.
- **`ExecutionContext.withRestored` forwards caller isolation**: new
  `isolation: isolated (any Actor)? = #isolation` parameter (mirroring
  `TaskLocal.withValue`) and the result's `T: Sendable` bound is removed, so
  actor-isolated callers can mutate their own state inside `operation`.
  Source-compatible.
- **`ProgressReporter.makeStream` now requires `bufferSize > 0`** (precondition):
  `.bufferingNewest(0)` silently dropped every update, a footgun with no valid use.
- **Documentation correctness pass**: `DEPENDENCIES.md` regenerated from
  `Package.swift`/`Package.resolved` (the previous file listed a dependency the
  package does not have); install instructions unified to `from: "0.5.2"` and
  corrected to the shipped requirements (Swift 6.2, platform 26.0+ floors);
  `ConcurrentPipeline` doc comments now name the errors actually thrown; the README
  performance table was removed (its numbers had no reproducible source);
  `BasicExample` and `AdvancedExample` are now real runnable programs and all
  bundled examples build as executables (`swift build` in `Examples/`); maintainer
  artifacts moved to `docs/internal/`, indexed by a new `docs/README.md`.
- Docs Pages deploys (per-PR/main and release) unified behind
  `Scripts/build-docs-site.sh`; weekly documentation audit extended to all seven
  public modules; doc-comment fill for `HealthCheckMiddleware`,
  `PartitionedBulkheadMiddleware`, `ObservabilitySystem`; guide code samples
  compile-verified (README, getting-started, guides, tutorials, command-bus
  series); `ResiliencePatterns.md` moved to `docs/guides/resilience-patterns.md`.

### Fixed
- **`StandardPipeline` could leave an attached progress stream unfinished**: a throw
  before the execution-context binding site — command-type mismatch, pre-start
  cancellation, or back-pressure rejection — skipped `finish()`, hanging any consumer
  iterating the stream. The finish obligation now lives at the `execute(_:context:)`
  entry point and covers every exit path. `DynamicPipeline` was never affected.
- **`ConcurrentPipeline` could leave an attached progress stream unfinished**: its
  handler-not-found, semaphore-acquire, and timeout throws all preceded delegation to
  the wrapped pipeline, so a reporter attached to the context was never finished. Both
  `execute` entry points now register the finish obligation first, covering every exit
  path; when the delegated pipeline finishes the stream first, the repeat `finish()`
  is a no-op.
- Method-level pages on the published docs site 404'd (filename sanitization ran
  before the Pages upload); release docs deploy was missing
  `--transform-for-static-hosting`.

### Removed
- CocoaPods and Carthage install instructions — both were "coming soon" promises;
  neither is supported (no podspec or Cartfile ships).
- `RELEASE_NOTES.md` and `RELEASE_NOTES_v0.3.0.md` — `CHANGELOG.md` is canonical.
- The `OTLPExample`, `StatsDExample`, and `TypeSafeMetricsExample` bundled examples —
  each demonstrated APIs that no shipped module provides (`OTLPExporter`, an
  exporter-decorator layer, a typed-unit metrics algebra). Examples are documentation
  and must compile against the shipped API; five buildable examples remain.
- `Examples/Package.resolved` from version control (examples build against the
  local parent; the lockfile drifted and guaranteed nothing).

## [0.5.1] - 2026-07-25

### Fixed
- **AsyncSemaphore could swallow a signal on cancellation**: when a `signal()` raced a
  parked waiter's cancellation, the cancelled waiter could be resumed as signaled —
  `wait()` returned normally in a cancelled task (violating its contract) and, because a
  cancelled caller never signals back, the consumed wakeup was lost and effective
  capacity shrank by one per occurrence. `wait()` (and `acquire(timeout:)`) now re-check
  cancellation after resuming, forward the consumed signal to the next waiter, and
  throw (respectively return `false`). The `wait()` doc now names the error actually
  thrown on cancellation, `PipelineError.cancelled`.
- **BackPressureSemaphore lost wakeup on cancellation**: the same race fixed in
  `SimpleSemaphore` (#73) existed in `BackPressureSemaphore.acquire()` — when a waiter's
  cancellation raced a token release, the release path could resume the already-cancelled
  waiter *with* a token, so a cancelled `acquire()` returned success and the permit could
  be stranded forever. `acquire()` now re-checks cancellation after resuming, forwards the
  permit, and throws `CancellationError`. Also fixed the cleanup task retaining the actor
  for the lifetime of its timer loop, which prevented `deinit` from ever running and leaked
  every semaphore (plus a once-per-second background task) past teardown.
- **SimpleSemaphore lost-wakeup deadlock** (#73): when a parked waiter's cancellation
  raced a token release, the release path could resume the already-cancelled waiter
  *with* a token, so a cancelled `acquire()` returned success and the permit could be
  stranded forever (the root cause of the long-standing ~1-in-15 "tests hang" CI
  mystery, issue #71). `acquire()` now re-checks cancellation after resuming, forwards
  the permit, and throws `CancellationError`.
- **StatsD sampling was a no-op for short metric names** (#69): the sampling hash (raw
  DJB2) never wraps `UInt64` for strings shorter than ~13 bytes, so the normalized hash
  collapsed toward 0 and rate-based sampling kept *everything* for typical metric names.
  Fixed with a splitmix64 finalizer — deterministic and stable across runs, now uniform.
  **Behavior change**: which specific names fall inside a sampling rate changes (the old
  behavior was degenerate); critical-pattern matching and rate 0.0/1.0 semantics are
  unaffected.
- **CI Stability**: Root-caused and fixed the flaky test-job failures first seen on the
  v0.5.0 release PR. The genuine failure was a timing race in
  `TimeoutDiagnosticTests.testDirectTimeoutUtility` (a 0.1s timeout racing a 0.2s
  operation lost under CI scheduler starvation); a stale `TARGET_EXIT_CODE` in the CI
  loop then cascaded false failures onto five other targets. Timing-race tests now let
  the losing branch lose by seconds; `EncryptionTests.testKeyRotation` polls for
  rotation instead of a fixed sleep; `AuditLoggingMiddlewareTests.testHealthStream`
  awaits its cancelled consumer task.

### Changed
- **CI**: re-enabled `swift test --parallel` in the per-target test loops. The
  historical parallel hang was the semaphore lost-wakeup family (#73/#74/#76),
  verified fixed with 50/50 clean local full-suite parallel runs under a
  hang-detection harness. Measured test-phase win is modest (89s → 82s; the big
  targets are dominated by wall-clock timing tests) — the primary value is
  removing the workaround and continuously stress-testing the concurrency
  primitives. Also widened the wall-clock sanity bound in
  `OptimizedValidatorsTests.testPerformanceComparison` (50ms → 0.5s), which
  flaked under parallel CPU contention.
- **Repo hygiene**: Removed `consolidated_library.md` (a 1.2 MB generated code-review
  dump with no references); reordered this changelog newest-first and repaired its
  version links; corrected stale claims in `.github/workflows/CI_NOTES.md`; aligned
  `.swift-version` (6.2) with the package manifest; grouped future Dependabot
  GitHub-Actions bumps into a single weekly PR.

## [0.5.0] - 2026-06-08

### Added
- `ObserverMiddleware` protocol (`observe(_:context:) async throws`) for side-effect/observer middleware that participate without a `next` closure. A default `execute` lets an observer drop into any sequential pipeline (observe, then forward to `next`).

### Changed
- **Breaking:** `ParallelMiddlewareWrapper` now takes `observers: [any ObserverMiddleware]` instead of `middlewares: [any Middleware]`, runs them concurrently, and propagates (cancelling siblings on) the first thrown error.
- `CommandContext` now uses `OSAllocatedUnfairLock` instead of `NSLock` for synchronization.
- `CircuitBreaker`'s internal state machine moved from an `actor` to an `OSAllocatedUnfairLock`-backed type — ~45× lower wall time under contention in a microbenchmark. Public API unchanged.

### Removed
- **Breaking:** `ParallelMiddlewareWrapper.ExecutionStrategy` (`.sideEffectsOnly` / `.preValidation`) and the `ParallelExecutionError` type. Side-effect/observer middleware should adopt `ObserverMiddleware`.

### Performance
- O(1) LRU caches via a doubly-linked-list store, replacing the O(n)-per-access `accessOrder` scans in `InMemoryCache` and `SimpleCachingMiddleware`.
- O(log n) waiter management in `AsyncSemaphore` and `BackPressureSemaphore` via the (previously unused) `PriorityHeap`, replacing O(n) array operations.
- The compiled middleware chain is cached per pipeline instead of rebuilt on every command; `DynamicPipeline` caches per command type with handler-registry invalidation.

### Fixed
- `EventHub` retain-cycle leak: the periodic cleanup task captured `self` strongly in an infinite loop, leaking every `EventHub` instance.
- `AsyncSemaphore` cancellation race (TOCTOU) that could orphan a waiter's continuation.
- `ParallelMiddlewareWrapper` now cancels sibling observers when one throws (previously `waitForAll()` let a slow sibling run to completion before the error propagated).
- `GracePeriodManager` uses a single cancellation-aware `Task.sleep` instead of a 10-chunk manual poll.

## [0.3.1] - 2025-10-18

### Fixed
- Removed unsafe build flags from all library and internal targets used by shipped products (PipelineKit, PipelineKitCore, PipelineKitCache, PipelineKitObservability, PipelineKitResilience, PipelineKitSecurity, PipelineKitPooling) so iOS app targets can link these products in Xcode 15+.
- Moved strict flags to tests only (kept `-enable-testing` on test targets). No `.unsafeFlags` remain on shipping targets.

### Notes
- Removed `-cross-module-optimization` from release builds of shipping targets to comply with SPM’s safety rules. If desired, pass this via CI (`swift build -Xswiftc -cross-module-optimization`).

## [0.2.0] - 2025-10-01

> These entries previously sat in a misplaced "Unreleased" section; they shipped in the
> `v0.2.0` tag.

### Fixed
- **Swift 6 Compliance**: Added `any` keyword to all protocol type usage for strict Swift 6 language mode compliance
  - Fixed protocol type warnings in `SimpleSemaphore.swift`, `DynamicPipeline.swift`, `MiddlewareChainBuilder.swift`
  - Fixed protocol type warnings in `StatsDExporter.swift`, `Command+Observability.swift`, `CommandContext+Events.swift`, `MetricsFacade.swift`
  - Fixed protocol type warnings in `AsyncSemaphore.swift`, `BackPressureSemaphore.swift`, `StandardPipeline.swift`
  - Added `@preconcurrency` import for OSLog in `SignpostMiddleware.swift` to handle Sendable warnings
- **CI Stability**: Fixed flaky `BackPressureMiddlewareTests.testStatsAccuracy` test by skipping on CI where timing is unreliable
- **Coverage Export**: Fixed coverage export format mismatch in multiplatform CI workflow
  - Now uses Swift toolchain's `llvm-cov` instead of system version
  - Changed output format from JSON to LCOV for better compatibility
  - Added proper error handling and debugging output
- **CI Configuration**: Removed Linux-specific `timeout` command from macOS CI workflows (not available on macOS)
  - Relies on job-level timeouts instead for better cross-platform compatibility

### Changed
- **Documentation**: Updated README.md for accuracy
  - Added visionOS to platform badge
  - Fixed module name typo (`PipelineKitCaching` → `PipelineKitCache`)
  - Updated installation version from 0.1.0 to 0.2.0
  - Added explicit platform version requirements section

## [1.0.0] - 2025-09-25

> Note: this release was published without a `v1.0.0` tag and versioning subsequently
> returned to the 0.x series.

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

[Unreleased]: https://github.com/gifton/PipelineKit/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.1
[0.5.0]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.0
[0.3.1]: https://github.com/gifton/PipelineKit/releases/tag/v0.3.1
[0.2.0]: https://github.com/gifton/PipelineKit/releases/tag/v0.2.0
