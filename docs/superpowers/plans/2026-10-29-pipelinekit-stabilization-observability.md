# PipelineKit observability and units Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate transport continuation failures, settle startup correctly, synchronize facade configuration and correct duplicate/unit accounting.

**Architecture:** Use one owned terminal transition for every UDP operation and one shared startup task per StatsD generation. Capture facade configuration before suspension and keep record and flush responsibilities distinct.

**Tech Stack:** Swift 6.2, XCTest, Network on Apple platforms, Foundation locks, ContinuousClock.

**Spec:** [Stabilization design](../specs/2026-10-29-pipelinekit-stabilization-design.md), “Observability and measurement.”

## Global Constraints

- Swift tools version remains 6.2; preserve existing language/concurrency settings and declared platform floors.
- Add no third-party dependencies. Use existing Atomics, CryptoKit/swift-crypto, Compression, Network and Foundation where already supported.
- Breaking changes are permitted; ship them in the next minor release under VERSIONING.md, with a Breaking entry and compiled migration examples. Do not invent or publish a release tag during implementation.
- Preserve the completed audit artifacts. Store remediation evidence separately and identify the exact source revision and local diff for each run.
- Do not lower assertions, skip failed regression cases, relax Sendable checking or replace production failures with successful defaults to make validation pass.
- Tests that coordinate races must acknowledge entry, grant, cancellation and settlement; sleeps alone do not establish ordering. Join all work created by the fixture. Use an external process watchdog for hang/crash probes.
- Resource permits remain owned until downstream work settles. This batch does not promise preemptive cancellation, hard deadlines for arbitrary handlers, durable execution or exactly-once side effects.
- Migrate all live callers of a changed API in the same task, including test fixtures; integration is not a holding area for uncompilable intermediate commits.
- A new gate or routing change requires tests of every newly reachable branch. A repeated defect class requires a mechanical regression matrix across its implementations.

Read the [master plan](2026-10-29-pipelinekit-stabilization.md) and [design](../specs/2026-10-29-pipelinekit-stabilization-design.md) before executing. All paths below are repository-relative. New test names are planned tests, not claims of current coverage. Commands are future execution instructions; retain their actual test counts and exit status. Each task ends with its own reviewed commit and a closure-ledger update; use explicit file lists, never blanket stage unrelated local work.

## Review Focus

1. Ready→cancelled or failed→cancelled must never resume setup twice: O01 scripts duplicate and late callbacks and runs real loopback.
2. A callback may never arrive, including after close: O01 resolves by owned deadline/cancellation without awaiting that callback.
3. Several nonempty batches can arrive while startup is pending: O02 preserves every batch and settles all callers on failure.
4. Configure/disable can race between record's two awaits and flush can duplicate delivery: O03 tests paired generations and exact record counts.
5. A one-second duration has zero fractional attoseconds: O04 tests whole-second and mixed durations, including saturation.

## Task O01: Own UDP setup, send, cancellation and close completion

**Finding IDs:** OBS-002, OBS-003. **Dependencies:** V01 watchdog.

**Files:** Modify `Sources/PipelineKitObservability/Transport/UDPTransport.swift`. Create `Sources/PipelineKitObservability/Transport/UDPConnectionDriver.swift`, `Tests/PipelineKitObservabilityTests/UDPTransportLifecycleTests.swift`, `Tests/PipelineKitObservabilityTests/Support/ScriptedUDPConnection.swift`. Create the initial real-network consumer in `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer/Sources/Consumer/main.swift` and `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer/Package.swift` now; I01 later expands it. Name the executable Consumer, use an ordinary PipelineKitObservability product import and a local dependency path of `../../../../..`, and implement the `udp-close` mode. This avoids depending on the later integration task for O01 validation.

**Interfaces:** Preserve MetricsTransport send/sendBatch/close. Internal `UDPConnectionDriver: Sendable` has `start(onState: @escaping @Sendable (UDPConnectionState) -> Void)`, `send(_: Data, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void)`, `cancel()`. UDPConnectionState: Sendable has ready, failed(TransportError), cancelled. An internal test initializer accepts a driver and controlled sleep closure; public initialization still constructs the real Network driver.

- [ ] Add `testSetupTerminalStateMatrix`: ready→cancelled, failed→cancelled, ready twice, cancel→late ready, and timeout→late ready. Assert one setup result, correct failure identity, no revival after close and all registry entries removed. Scripted driver records exact callback/resume counts.
- [ ] Add `testMissingSendCallbackSettlesOnTimeoutOrClose`, cancellation before registration/after completion and concurrent sendBatch failure tests. Withhold callbacks deliberately, advance the controlled deadline and assert caller settlement without releasing a callback later. Late callback must be harmless.
- [ ] Run `swift test --filter UDPTransportLifecycleTests` under the V01 watchdog. Preserve audit V406 as observed baseline crash; a new test seam's compile-red is not another runtime crash. First real baseline rerun, if needed, must be subprocess-isolated.
- [ ] Implement a stable operation ID and actor-serialized pending-operation registry. Ready/failure/cancel/deadline remove the record before resuming. Attach task cancellation and deadline ownership at registration; no raw continuation can outlive all terminal owners. Close invalidates the connection and settles every pending operation.
- [ ] Validate port 1...65535, finite positive timeout/connectionTimeout and positive maxRetries. A send timeout/cancellation invalidates and cancels the shared connection, settles siblings, and makes later sends fail. Retry only recoverable reported send errors; propagate cancellation instead of swallowing cancelled backoff sleep. The real driver serializes its own mutable Network state and documents any unchecked Sendable boundary.
- [ ] Run the scripted filter in Debug and Release. Run this task’s real `udp-close` consumer mode with an ephemeral local listener: await ready, send a synthetic datagram, acknowledge receipt, close twice and exit cleanly. Expected exit 0, no SIGTRAP and no watchdog timeout; also test real failure→close when reliably inducible.
- [ ] Update both rows with separate scripted and real evidence; commit `fix(transport): settle UDP operations exactly once on every terminal path`.

## Task O02: Route all StatsD construction through owned transport startup

**Finding ID:** OBS-004. **Dependencies:** O01. Do not combine with unselected sampling/aggregation repairs.

**Files:** Modify `Sources/PipelineKitObservability/Exporters/StatsDExporter.swift`, `Tests/PipelineKitObservabilityTests/StatsDExporterTests.swift`; create `Tests/PipelineKitObservabilityTests/StatsDStartupContractTests.swift`. Extend `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer/Sources/Consumer/main.swift` with the `statsd-startup` mode. Adapt `Sources/PipelineKitObservability/Metrics/MetricsFacade.swift` constructor use only as needed for this API; O03 owns its state redesign. Migrate the live async-constructor calls in `Sources/PipelineKitObservability/ObservabilitySystem.swift` and `Examples/Sources/MetricsAggregationExample/MetricsAggregationExample.swift`, preserving readiness/error behavior through explicit start where required; no unrelated system/example redesign.

**Interfaces:** Keep sync lazy `init(configuration: Configuration = .default)`; add sync `init(configuration: Configuration, transport: any MetricsTransport)`, `start() async throws`, `close() async`. Remove useTransport and the competing async initializer. Internal factory injection is `@Sendable () async throws -> any MetricsTransport`. setErrorHandler accepts an optional `@Sendable (any Error) -> Void` so O03 can install or clear before publication. Existing forceFlush remains.

- [ ] Add `testConcurrentNonemptyBatchesWaitForOneStartup`: maxBatchSize=1, aggregation disabled, three distinct records and a gated factory. Before ready there are zero sends; after ready all three batches are accounted for exactly once, factoryStarts=1 and all caller tasks finish.
- [ ] Add `testStartupFailureSettlesEveryBatchAndCanRestart`, `testCloseDuringStartupClosesLateTransport`, `testRecordAfterCloseReportsFailure`. Assert each failed batch is observable, no overwritten waiter, no late transport leak, and next generation cannot be replaced by a stale completion. Use nonempty forceFlush fixtures; empty flush is not evidence.
- [ ] Run `swift test --filter StatsDStartupContractTests`; retain the source-confirmed legacy schedule as baseline if it cannot be forced without the new driver. Explicitly record whether old first-batch loss was observed.
- [ ] Remove legacy NWConnection state and the useTransport gate. Own one generation-tagged startup task; keep each batch in its caller until readiness/error. Clear failed generation for a later retry. Implement close per design: mark closed, cancel flush timer/startup, settle/close resources and discard unsent buffer; forceFlush-before-close is the delivery attempt path.
- [ ] Run the new filter plus StatsDExporterTests in Debug and Release. Run the `statsd-startup` real default-constructor first-batch loopback case, not only injected mocks. Verify conditional non-Network failure is explicit and reported.
- [ ] Update OBS-004 and migration examples; list OBS-001/005/009 as still open. Commit `fix(statsd): share startup ownership across default and injected transports`.

## Task O03: Publish coherent Metrics configuration and stop flush replay

**Finding IDs:** OBS-008, OBS-007. **Dependencies:** O02; coordinate its MetricsFacade edits.

**Files:** Modify `Sources/PipelineKitObservability/Metrics/MetricsFacade.swift`, `Sources/PipelineKitObservability/Metrics/MetricRecorder.swift`, `Sources/PipelineKitObservability/Exporters/StatsDExporter.swift`, `Tests/PipelineKitObservabilityTests/MetricsFacadeTests.swift`. Create `Tests/PipelineKitObservabilityTests/MetricsConfigurationContractTests.swift`.

**Interfaces:** Public immutable `Metrics.Configuration: Sendable` contains `storage: MetricsStorage`, `exporter: any MetricRecorder`, `errorHandler: (@Sendable (any Error) -> Void)?`, with an explicit initializer. `Metrics.configure(_: Configuration) async` prepares a StatsD callback then atomically publishes; `configure(with: any MetricRecorder) async` and host convenience delegate. `Metrics.configuration: Configuration` is read-only; remove writable storage/exporter/errorHandler slots. disable remains a synchronized mutation. New `FlushableMetricRecorder: MetricRecorder` requires `flush() async`; StatsD exposes it by forwarding to forceFlush and renames its internal method to flushBuffer. For deterministic testing, factor the facade record path into internal `record(_ snapshot: MetricSnapshot, afterStorage: (@Sendable () async -> Void)? = nil) async`; ordinary public methods pass no hook. It captures configuration before storage, then invokes the optional test hook after storage and before export.

- [ ] Add `testRecordUsesOneConfigurationAcrossSuspension`: use the internal afterStorage hook to pause generation A between storage and export, configure B, release A; assert A's storage/exporter receive the same record and B receives none of that operation. Later records go entirely to B. Repeat configure/disable and flush overlap with distinct recorder instances.
- [ ] Add `testFlushDoesNotRecordSnapshotsAgain`: record one metric, flush twice; recorder.recordCount remains 1 and flushCount becomes 2. Storage drain is empty after the first completed flush. Add a custom nonflushable recorder control.
- [ ] Add `testConfigurationCallbacksCanReenterAndRelease`: replacing the last owned snapshot releases its callback captures after in-flight records finish; callback re-entry into configure/disable cannot deadlock. Restore test globals explicitly in each fixture; do not depend on the uninitialized global teardown observer LS-008.
- [ ] Run `swift test --filter 'MetricsConfigurationContractTests|MetricsFacadeTests'`; expected duplicate-export red and old API/new snapshot compile red. Preserve the audited unsafe-slot evidence until TSan.
- [ ] Implement a private locked configuration owner, capture one snapshot per operation, and publish only prepared exporters. No callback or await runs under its lock. Remove re-recording from flush; drain captured storage and call captured FlushableMetricRecorder.flush when available. Do not auto-close retired exporters or claim a barrier for concurrently starting records.
- [ ] Run the same tests in Debug and Release, then the focused TSan command in I01. Document that reusing the same mutable recorder across configurations intentionally shares that recorder's state; the snapshot is not a deep clone.
- [ ] Update both rows; commit `fix(metrics): synchronize configuration and avoid duplicate flush exports`.

## Task O04: Correct timer and pool latency units

**Finding IDs:** OBS-011, SCP-15. **Dependencies:** none beyond V01.

**Files:** Modify `Sources/PipelineKitObservability/Types/Metric.swift`, `Sources/PipelineKitPooling/ObjectPool.swift`, `Tests/PipelineKitObservabilityTests/TypeSafeMetricTests.swift`. Create `Sources/PipelineKitPooling/DurationNanoseconds.swift`, `Tests/PipelineKitPoolingTests/DurationNanosecondsTests.swift`.

**Interfaces:** Preserve typed timer APIs; duration input is seconds and produced unit ms. Internal `durationNanosecondsClamped(_ duration: Duration) -> UInt64` includes whole seconds, truncates sub-nanosecond remainder, clamps nonpositive values to 0 and saturates overflow at UInt64.max. Both acquisition/release metrics use it.

- [ ] Add `testTypedAndSnapshotTimerUnitsAgree` for 0/0.25/1/1.25 seconds. Assert value equals 0/250/1000/1250 with floating-point accuracy tolerance and unit=ms in both representations. Replace the old incorrect expectation rather than changing both implementations to the wrong unit.
- [ ] Add `testDurationNanosecondsIncludesWholeSeconds` and `testDurationNanosecondsClampsBoundaries`: 0.25→250,000,000; 1→1,000,000,000; 1.25→1,250,000,000; negative→0; below/above UInt64 representability limit obey truncation/saturation. Also include a positive Duration constructed with a negative fractional component (1 second minus 0.25 seconds → 750,000,000 ns). Use synthesized Duration values, no real delays.
- [ ] Run `swift test --filter 'TypeSafeMetricTests|DurationNanosecondsTests'`; expected units red/new-helper compile red.
- [ ] Multiply typed timer seconds by 1,000 once. Implement checked whole/fraction arithmetic in the private helper and use it at both pool sites. Search all attoseconds-only duration conversions in touched products and extend this matrix for any second equivalent occurrence.
- [ ] Re-run both filters and ObjectPoolTests. Expected exact integer nanoseconds and tolerant floating timer equality, without changing pool resource ownership.
- [ ] Update both rows; commit `fix(metrics): preserve whole seconds and consistent timer units`.

