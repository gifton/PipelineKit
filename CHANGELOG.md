# Changelog

All notable changes to PipelineKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `BatchIngestExample`: a batch ingest pipeline with one command per batch, bounded
  concurrency and outstanding work through `BackPressureMiddleware`, and metrics the program
  reads back and checks. CI builds and runs it with the other examples.

### Documentation

- README restructured as an entry point: first example, reasons to choose or not choose the
  package, module map, and links to the documentation site. Reference material moved to
  `docs/guides/architecture.md`, `docs/guides/performance.md`, `docs/guides/resilience-patterns.md`,
  `docs/guides/security-best-practices.md`, `docs/tutorials/custom-middleware.md` and
  `docs/tutorials/advanced-patterns.md`. Statements the code did not back were removed.
- Documentation defects fixed: the printed `Middleware` protocol and the middleware examples
  now show `next` as `@escaping`; wording that told readers to wait for the `v0.6.0` tag is
  gone; the security guide's table of contents links resolve; `Tests/README.md` lists the
  test targets that exist. `docs/getting-started/quick-start.md` is removed: the README's
  first pipeline and `docs/tutorials/basic-usage.md` cover the same ground. The performance
  and resilience guides now state that `StandardPipeline` applies only `maxConcurrency` from
  `PipelineOptions`. CI checks that relative documentation links and anchors resolve and that
  protocol requirements printed in the documentation match the source.
- The documentation index (`docs/README.md`) now gives two reading paths in order and states
  which surface holds which kind of content. New `docs/guides/testing.md` covers
  `PipelineKitTestSupport`. The command-bus book ends with a table mapping its teaching bus
  onto PipelineKit's types. The documentation site's Getting Started article and
  `docs/guides/enterprise-evaluation.md` are now compiled in CI.
- The ten 0.6.0 migration notes are consolidated into one upgrade guide,
  `docs/migrations/0.5-to-0.6.md`, organised by module and opened by a section on data
  written by 0.5.x. Every Swift example in it is compiled in CI. The qualification records
  remain at the `v0.6.0` tag. Statements that later 0.6.0 work had superseded were removed,
  and two instructions were corrected against the source: a distributed rate-limit status
  lookup throws the store's error (the notes said its read-error behavior was unchanged), and
  the task-scoped warning suppression is `NextGuard.withoutWarnings` (the notes named
  `NextGuardConfiguration`). `docs/migrations/release-readiness.md` is a pointer to the new
  guide until the next tagged release.

### Changed

- **Minimum deployment targets lowered** from OS 26 to macOS 15, iOS 18, tvOS 18, watchOS 11
  and visionOS 2. No source change was needed, and existing users need to do nothing: a
  package or app that already builds against PipelineKit keeps building. The package is
  compiled for these targets on every pull request. Two advisory CI lanes run
  the tests on a macOS 15 runner and on an iOS 18 simulator; both passed on their first run
  (2026-11-11). tvOS, watchOS and visionOS are compiled and not run. The runners provide macOS 15.8 and
  iOS 18.5, so the first releases of that OS generation (macOS 15.0 to 15.3, iOS 18.0 to
  18.3, which ship an older Swift runtime) are not exercised.
- Benchmark harness runs its workloads off the main thread; records made with the earlier
  harness are not comparable with new ones. First published results are in `docs/benchmarks.md`.
- Examples: `AdvancedExample` is renamed `MiddlewareStackExample`; `MetricsSamplingExample`
  and `MetricsAggregationExample` are merged into `StatsDExportExample`, which runs both
  checks unchanged.

## [0.6.0] - 2026-11-07

### Breaking

Consolidated after release: [Upgrading from 0.5.4 to 0.6.0](docs/migrations/0.5-to-0.6.md) replaces the per-topic notes linked below, which remain available at the `v0.6.0` tag.

See the [compiled migration guide](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/first-stabilization-batch.md) before upgrading.
0.6.0 contains source and behavior changes from 0.5.4. See the
[release readiness migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/release-readiness.md)
for caller updates, qualification evidence, and remaining limits.

- The [release qualification migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/release-qualification.md)
  covers throwing rate-limit status queries, typed middleware mocks and throwing
  test controls, and removal of the unfinished `MemoryProfiler` API.
- Remove deprecated `BulkheadMiddleware.IsolationMode.tagged`; use declared
  partitions with `allowBorrowing: false` for independent capacity. Remove the
  `maxBorrowPercentage` property and initializer parameter; use
  `reservedCapacityPercentage` with the same reserved-share meaning.
- Rate state cleanup now preserves configured quotas beyond five minutes. A
  leaky bucket starts a new leak interval when an empty bucket admits work;
  partially occupied buckets retain their fractional leak phase. Wall-clock
  rollback freezes local policy time until the clock catches up. Depleted
  zero-refill and adaptive token state may remain resident until explicit reset.

- The [resilience policy migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/resilience-policy-contracts.md)
  documents monotonic retry budgets, required HTTP status extraction, removal of ignored
  timeout options, per-execution grace outcomes, explicit rate priority and throwing reset,
  strict outstanding limits, and chronological oldest-waiter eviction.

- The [monitoring lifecycle migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/monitoring-and-connection-lifecycle.md)
  documents joined health/memory shutdown, the callback self-stop exception,
  generation-safe memory monitoring and observer cleanup, and hub-owned metrics
  connections with explicit disconnect identifiers. Ordinary subscriptions remain weak.

- The [error and cancellation migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/error-cancellation-and-validation.md)
  documents typed cancellation at pipeline/semaphore boundaries, cancellation-proof
  retry and failure scoring, default exclusion of non-service errors, and typed
  breaker, bulkhead, and encryption failures. Health configuration gains a custom
  error predicate. Test timeout helpers now distinguish their own deadline from
  operation errors, and checkpoint waits have a cancellation-aware throwing API.

- The [telemetry migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/telemetry-hardening.md) documents cumulative
  Prometheus scrape state, configurable series limits, recent-window pool percentiles,
  and corrected StatsD delivery/sampling. Raw history drains no longer reset scrape
  totals; explicit storage clear/reset does. Invalid or colliding wire definitions
  are omitted with diagnostics. Pool snapshot label keys are now quoted and escaped.

- See the [security, serialization, and numeric migration](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/security-serialization-and-numeric-safety.md)
  for actual compression format names, removed ignored level options, and the explicit
  legacy-label decoder. Custom encrypted result fields use the opt-in
  `SerializedPlaintextDecrypting` capability; existing typed encryption services remain valid.
  Numeric configuration now rejects invalid inputs before conversion, preserves intentional
  zero/no-wait behavior, and bounds derived arithmetic. Only admission waits have a 24-hour cap.
- Follow-up admission and security changes are described in the
  [core stabilization notes](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/core-admission-and-security.md).
  Configured admission deadlines now take effect, nil pipeline capacity limits are
  honored, and automatic security validation counts supported leaves inside containers
  and inherited fields. Reflected reference cycles require custom validation.
- Validation and sanitization require explicit async capability conformance by default;
  `.ifPresent` is an explicit opt-out. Mixed builder families now retain every configured stage
  and its effective order, which can activate previously omitted policy checks.
- Command encryption requires complete `Codable` commands. `EncryptedCommand.originalCommand`
  and partial-field hooks are removed; envelopes retain only ciphertext and metadata.
  KeyStore publishes one atomic key/identifier snapshot and keys must be 256 bits.
  Legacy ciphertext may be insufficient for recovery without original commands and old keys.
- All four cache entry points and factories require complete caller keys including every
  result-varying argument, verified principal/tenant and configuration/version. Keyless/hash
  fallbacks are removed. Invalidate all old cache contents; namespace encoding has changed.
- Decompression requires positive `maxOutputSize`, returns a complete bounded stream or throws,
  and rejects truncation/trailing data. Small nonempty utility compression now emits codec data;
  old unmarked raw outputs require application metadata or regeneration. Historical codec
  labels are supported by the explicit legacy decoder described above.
- Ordinary and partitioned bulkhead queue timeouts accept finite positive values up to 86,400
  seconds, finite nonpositive values for no wait, and nil for unbounded waiting. Nonfinite or
  larger positive values are invalid. Nil is not an equivalent finite deadline above 24 hours.
  Capacity remains owned until handlers settle; no hard arbitrary-handler deadline is added.
- Global rate scope shares one budget across identifiers in all seven strategies. Distributed
  keys use scope namespaces; coordinate old/new counter migration to avoid a fresh cold budget.
- Retry/breaker timeout classification uses typed PipelineError cases. Other PipelineError
  payload text, including wrapped/retryExhausted errors, does not imply timeout or recursive
  unwrapping. Custom evaluators and foreign-error fallback remain available.
- StatsD construction is synchronous and lazy; `useTransport` and the competing async initializer
  are removed. `start()` validates readiness; injected transports transfer shutdown ownership.
  Quiesce producers, forceFlush, then close for a delivery attempt. Close owns exporter/startup/
  transport settlement, not complete aggregation quiescence or UDP acknowledgement.
- Metrics configuration is immutable and published through async `configure`; direct writable
  global slots are removed. Flush drains local storage and invokes an optional flush capability
  without replaying records; it is not a concurrent-producer barrier or retired-exporter flush.
- Truncation returns empty for nonpositive maxima. Audit logger capacity zero retains no events;
  negative capacity is invalid. Standard audit identity keys are retained in production output.
  Timer milliseconds and pool nanoseconds now use corrected unit/boundary conversion.


### Changed
- Release metadata and installation guidance target 0.6.0, with an explicit
  `"0.6.0"..<"0.7.0"` dependency range to avoid automatic source-breaking minor upgrades.
- The resolved swift-log dependency is 1.16.2, up from 1.15.0 in 0.5.4;
  the declared package requirement is unchanged.
- All five standalone examples now verify their outcomes in Debug and Release,
  including captured metrics and a real authenticated encryption round trip.
  Shared PR/tag qualification requires successful execution and verified markers.
  The [example migration rehearsal](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/examples-rehearsal.md) records
  unchanged v0.5.4 caller builds and executions against both library revisions.
- Performance baseline/update/compare commands now produce and consume checked
  Release JSON records with matching workload, hardware, toolchain, and dependency
  identities. Comparisons report batch timing ratios with explicit advisory or
  enforced limits; allocation evidence is labeled unavailable.
- The shared qualification workflow adds a Swift 6.2 compiler build check and
  Debug/Release tvOS and visionOS simulator builds. watchOS builds remain advisory.
- Version tags run the shared Debug/Release, numeric, compression, public-consumer,
  and telemetry qualification gates. Publication requires exact nonempty release
  notes and a successfully generated documentation artifact.
- CI now executes the Release correctness tests, with failures blocking the job;
  performance benchmarks retain their separate advisory lane.
- `NextGuard` debug diagnostics are now error-exit aware: middleware that
  throws without calling `next()` no longer emits the false "deallocated
  without calling next()" warning — the middleware chain now marks the guard
  before rethrowing. `NextGuardWarningSuppressing` is only needed for
  middleware that *returns* a result without calling `next()` on a normal
  path (e.g. cache hits). Debug-only; release builds are unchanged. ([#97](https://github.com/gifton/PipelineKit/issues/97))

### Fixed
- `ExecutionTracer` enforces trace capacity and reports rejected traces;
  `ExecutionTracerTests` covers zero capacity, retention, and reused traces.
- `TestPipeline` settles explicitly attached progress reporters on success,
  failure, and cancelled admission while preserving inherited parent ownership;
  `TestPipelineProgressContractTests` exercises those routes.
- Retry callback-budget tests now control expiry at the intended callback.
  Timeout middleware-order tests use cancellable suspended work and run in CI
  and simulators without their previous timing exclusion or retry loop.
- HTTP health-check outcome tests now use local session fixtures, including real
  request cancellation, instead of always skipping or contacting an external domain.
- `CommandContext` evaluates metadata getters and value descriptions outside its
  storage lock, permitting callbacks to read or mutate the same context. Retired
  values remain alive through unlock; focused callback and retirement tests cover
  description, snapshots, clear, and mutation.
- Rate-limit cleanup uses policy-specific reclamation conditions and guards
  state identity across admission, status, and reset interleavings. It no longer
  grants a fresh budget merely because an identity was idle for 300 seconds.
- Test mock readers take locked snapshots, and stress CI propagates test and
  discovery failures instead of reporting a successful empty or failed run.
- Encrypted result decoding preserves authenticated serialized bytes for custom objects,
  arrays, and hintless envelopes; authentication failures throw before plaintext is returned.
  Type and encoding hints remain unauthenticated metadata.
- Security guide examples now mask enriched audit metadata and place error sanitization
  and metrics outside authentication. Fractional pool intervals retain their precision;
  retry, timeout, rate-limit, and pooling numeric boundary regressions are covered.
- Rate-limit cleanup conditionally removes unchanged idle token-bucket and sliding-window
  entries, preserving admissions and resets that occur while cleanup awaits child actors.
- Semaphore cancellation handlers share immutable waiter identifiers. Concurrent pipeline
  capacity is explicitly released when the handler settles.

### Removed
- `NextGuardWarningSuppressing` conformance removed from the eleven
  throw-based short-circuiting middlewares (`BackPressureMiddleware`,
  `CircuitBreakerMiddleware`, `RateLimitingMiddleware`,
  `EnhancedRateLimitingMiddleware`,
  `PartitionedBulkheadMiddleware`, `HealthCheckMiddleware`,
  `ValidationMiddleware`, `SecurityPolicyMiddleware`,
  `AuthenticationMiddleware`, `AuthorizationMiddleware`,
  `MockAuthenticationMiddleware`), re-arming the dropped-chain diagnostic
  for those types. Observable only to code checking
  `is any NextGuardWarningSuppressing`; the cache middlewares keep the
  conformance. `BulkheadMiddleware` also retains the marker because successful
  fallback/custom policies can legitimately return without calling `next()`. ([#97](https://github.com/gifton/PipelineKit/issues/97))

### Performance advisory
- Two hosted comparisons reported admission median ratios of 1.178 and 1.143
  against the pre-runtime-correction baseline. A bounded local comparison did
  not reproduce that increase (median ratio 0.990 across four balanced pairs),
  but failed its quiet-host condition and used a different compiler and host.
  The cause remains unresolved; this is an advisory under the benchmark policy,
  not a claim that a regression was cleared or that battery state caused it.
  See the [qualification evidence](https://github.com/gifton/PipelineKit/blob/v0.6.0/docs/migrations/release-readiness.md#qualification-snapshot).

## [0.5.4] - 2026-08-15

### Deprecated
- `PartitionedBulkheadMiddleware.Configuration.maxBorrowPercentage` (and its
  init parameter): renamed to `reservedCapacityPercentage` — the value has
  always been the lender's *reserved* share, not a borrowing cap. Semantics
  unchanged; the old spellings forward and will be removed in 0.6.
- `BulkheadMiddleware.IsolationMode.tagged`: never provided per-tag isolation
  (all tags share one semaphore; the tag is context metadata only, [#86]).
  Use `PartitionedBulkheadMiddleware` with `allowBorrowing: false`. Removal
  in 0.6.

### Fixed
- `CircuitBreakerMiddleware`: a half-open probe that exited via a
  non-triggering error (e.g. cancellation) left the probe slot claimed
  forever, permanently rejecting all traffic; abandoned probes now release
  the slot. Half-open transitions are now driven solely by the probe's
  outcome — stale requests admitted before the circuit opened can no longer
  close it, admit extra probes, or re-open it. ([#92])
- Rejection paths of `BackPressureMiddleware`, `CircuitBreakerMiddleware`,
  `RateLimitingMiddleware`, `EnhancedRateLimitingMiddleware`,
  `BulkheadMiddleware`, `PartitionedBulkheadMiddleware`,
  `HealthCheckMiddleware`, `ValidationMiddleware`, and
  `SecurityPolicyMiddleware` no longer emit false debug
  "NextGuard deallocated without calling next()" warnings: all nine now
  conform to `NextGuardWarningSuppressing`, matching the caching and auth
  middlewares.
- `AuthenticationMiddleware` documentation no longer references
  `AuthenticationError`, a type that does not exist; the middleware rethrows
  whatever the `authenticate` closure throws, and the docs now say so.

## [0.5.3] - 2026-08-08

### Fixed
- `CommandContext.recordCounter`/`recordGauge`/`recordTimer` now actually
  record the caller's metric: `MetricsEventBridge` handles the explicit
  `metric.*.recorded` events (bypassing the derived-metric config gates, so
  explicit records also work under `.production`) instead of dropping the
  name, value, and tags in its generic fallback. ([#85])
- `ConcurrentPipeline.execute(_:context:timeout:)`: removed the unreachable,
  misleading `PipelineError.timeout` branch; the defensive path now matches
  the documented `.backPressure(.timeout)` contract. ([#88])

## [0.5.2] - 2026-07-31

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
- `VERSIONING.md`: the 0.x compatibility promises, SwiftPM pinning semantics
  (`from:` accepts source-breaking 0.x minors; the range form does not), and the
  untagged-1.0.0 explanation.
- `docs/platform-support.md`: exact platform floors and what CI actually
  verifies per platform (tvOS/visionOS are declared floors with no CI lane;
  Linux is best-effort and non-blocking); README links it.
- `docs/guides/enterprise-evaluation.md`: a 30-minute proof-of-concept path and
  an honest stable-vs-newer surface map, linking the tracked known issues.

### Changed
- Root `SECURITY.md` is now a standard security policy (supported versions,
  private vulnerability reporting — newly enabled on the repository, scope).
  The former best-practices content moved to
  `docs/guides/security-best-practices.md` and was corrected against the
  shipped API and real CI automation: middleware examples use the real
  `execute(_:context:next:)` protocol, the fabricated `SecurityOrder` enum and
  `HTTPCommandMetadata` are gone, and dependency/automation claims now state
  what actually runs; context.userID is clarified as unauthenticated.
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
- **Docs site tooling and coverage fill**: Docs Pages deploys (per-PR/main and
  release) unified behind `Scripts/build-docs-site.sh`; weekly documentation audit
  extended to all seven public modules; doc-comment fill for
  `HealthCheckMiddleware`, `PartitionedBulkheadMiddleware`, `ObservabilitySystem`,
  and five `PipelineKitTestSupport` file banners (`ActorTestMiddleware`,
  `TestCounter`, `TestPipeline`, `TestSynchronizer`, `TimeoutTester`); guide code
  samples compile-verified (README, getting-started, guides, tutorials,
  command-bus series); `ResiliencePatterns.md` moved to
  `docs/guides/resilience-patterns.md`.

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
- **Method-level docs pages 404'd on the published site**: filename sanitization
  ran before the Pages upload; release docs deploy was missing
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

## [1.0.0] - 2025-09-25 (never tagged)

> Note: there is no `v1.0.0` tag and no 1.0.0 release to depend on. This entry records
> changes made on that date; versioning continued in the 0.x series.
> See [VERSIONING.md](VERSIONING.md).

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

[Unreleased]: https://github.com/gifton/PipelineKit/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/gifton/PipelineKit/releases/tag/v0.6.0
[0.5.4]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.4
[0.5.3]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.3
[0.5.2]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.2
[0.5.1]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.1
[0.5.0]: https://github.com/gifton/PipelineKit/releases/tag/v0.5.0
[0.3.1]: https://github.com/gifton/PipelineKit/releases/tag/v0.3.1
[0.2.0]: https://github.com/gifton/PipelineKit/releases/tag/v0.2.0
[#85]: https://github.com/gifton/PipelineKit/issues/85
[#86]: https://github.com/gifton/PipelineKit/issues/86
[#88]: https://github.com/gifton/PipelineKit/issues/88
[#92]: https://github.com/gifton/PipelineKit/issues/92
[#97]: https://github.com/gifton/PipelineKit/issues/97
