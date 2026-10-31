# PipelineKit first stabilization batch

Status: proposed implementation design; source changes have not started. The owner explicitly accepts breaking changes. This document and the linked plans define the requested first batch, not authorization to publish a release.

## Intent and evidence

Repair all **17 high-impact findings** and **20 selected findings from the other 67** in the completed local audit. The remaining **47** stay in the follow-on backlog. Of the 20 additions, four are necessary adjacent repairs (SCP-03, SCP-05, R-F04, OBS-003); sixteen are small, localized fixes or validation repairs. This is a substantial stabilization batch, not 37 equally sized edits.

The baseline is `a93a713d937e25f68855f22b0720f33c93329b09` on `refactor/nextguard-throw-aware-diagnostics`, including the local files identified in the [audit manifest](../../../audit/pipelinekit/2026-10-28-a93a713-local/baseline-manifest.json). The [findings register](../../../audit/pipelinekit/2026-10-28-a93a713-local/FINDINGS.md), [architecture](../../../audit/pipelinekit/2026-10-28-a93a713-local/ARCHITECTURE.md), [validation record](../../../audit/pipelinekit/2026-10-28-a93a713-local/VALIDATION.md), current source, and [versioning policy](../../../VERSIONING.md) are the inputs. Historical plans supply context, not proof of current behavior.

The [master plan](../plans/2026-10-29-pipelinekit-stabilization.md) owns the complete 84-row scope ledger, task dependencies and closure requirements. Each subsystem has its own executable plan. No audit finding is closed by writing this design.

## Global constraints

- Swift tools version remains 6.2; preserve existing language/concurrency settings and declared platform floors.
- Add no third-party dependencies. Use existing Atomics, CryptoKit/swift-crypto, Compression, Network and Foundation where already supported.
- Breaking changes are permitted; ship them in the next minor release under VERSIONING.md, with a Breaking entry and compiled migration examples. Do not invent or publish a release tag during implementation.
- Preserve the completed audit artifacts. Store remediation evidence separately and identify the exact source revision and local diff for each run.
- Do not lower assertions, skip failed regression cases, relax Sendable checking or replace production failures with successful defaults to make validation pass.
- Tests that coordinate races must acknowledge entry, grant, cancellation and settlement; sleeps alone do not establish ordering. Join all work created by the fixture. Use an external process watchdog for hang/crash probes.
- Resource permits remain owned until downstream work settles. This batch does not promise preemptive cancellation, hard deadlines for arbitrary handlers, durable execution or exactly-once side effects.
- Migrate all live callers of a changed API in the same task, including test fixtures; integration is not a holding area for uncompilable intermediate commits.
- A new gate or routing change requires tests of every newly reachable branch. A repeated defect class requires a mechanical regression matrix across its implementations.

## Scope and sequencing

Selected high-impact IDs: PK-F001, PK-F004, PK-F006, SCP-01, SCP-02, SCP-04, SCP-07, R-F01, R-F02, R-F03, R-F07, R-F08, R-F15, R-F21, OBS-002, OBS-004, OBS-008.

Selected additions: PK-F002, PK-F003, PK-F005, PK-F007, PK-T001; SCP-03, SCP-05, SCP-06, SCP-11, SCP-12, SCP-15, SCP-17; R-F04; OBS-003, OBS-007, OBS-011; SUP-002; CI-002, CI-004; LS-007.

Start by repairing unreliable validation. Then land independently reviewable core, security/cache, resilience and observability tasks. Integrate builder and security changes before treating the configured security chain as repaired. Finish with external-consumer compilation, complete Debug/Release unit runs, targeted sanitizer and real Network tests, migration documentation, and a per-ID closure review. Neither a passing aggregate test count nor a local mock alone closes a consequential finding.

## Core composition and configuration

### One middleware sequence with effective order

Use an internal `MiddlewareEntry` containing the original `any Middleware`, an `Int` effective priority and stable insertion ordinal. Every PipelineBuilder family adds to this sequence. An explicit order overrides the middleware's intrinsic priority; equal priorities retain insertion order. StandardPipeline must retain the effective priorities when building and invalidating its chain. Direct additions continue to use intrinsic priority.

Do not hide middleware in a priority-only wrapper: MiddlewareChainBuilder must still recognize UnsafeMiddleware, conditional/scoped middleware and warning-suppression markers in both Array and ContiguousArray paths. Introspection should report the effective order of these entries. This closes PK-F001/002, not all inspector defects in PK-F010.

### Routing and ownership

Co-locate DynamicPipeline's handler storage and cached chains in the DynamicPipeline actor. Extract a synchronous internal `HandlerRegistryStorage` value that can also back the existing internal HandlerRegistry actor; do not add another independently mutable cache generation across an await. Registration/replacement/removal and cache invalidation occur in the same actor turn. Selection and cache publication also occur without suspension. After `replace` returns, every newly selected send uses the replacement. An already selected in-flight send may finish using the old handler.

Capture the immutable local handler in StandardPipeline's cached terminal closure, not the pipeline. In CommandContext, metrics read/merge/write must share one existing metadata-lock critical section. Preserve the current per-key last-writer-wins rule; disjoint updates cannot disappear.

### Warning state

NextGuardConfiguration owns a lock-protected immutable snapshot of `emitWarnings` and the callback. Keep convenient property access through synchronized computed properties; multi-property setters/reset publish one snapshot. A guard's deinit reads one snapshot and invokes its retained callback after releasing the lock.

`withoutWarnings` uses a TaskLocal Boolean, for both synchronous and asynchronous overloads. Capture that Boolean into the guard's instance suppression field at construction, so an escaped guard retains the scope's diagnostic decision. Nested scopes restore automatically; unrelated tasks and permanent global configuration changes are unaffected. Existing throw-exit and explicit middleware suppression remain intact. No callback executes under the configuration lock.

## Security, identity and data

### Real capabilities, explicit absence

Replace extension-only Command hooks with public protocols in PipelineKitSecurity:

```swift
public protocol ValidatableCommand: Command {
    func validate() async throws
}
public protocol SanitizableCommand: Command {
    func sanitize() async throws -> Self
}
public enum SecurityCapabilityRequirement: Sendable {
    case required, ifPresent
}
```

ValidationMiddleware and SanitizationMiddleware take `requirement: SecurityCapabilityRequirement = .required`. Missing required conformance throws `SecurityCapabilityError.missingValidation(commandType:)` or `.missingSanitization(commandType:)` before calling next. `.ifPresent` is the explicit opt-out for mixed command sets. Invoke protocol witnesses through the generic pipeline, and pass the returned sanitized value to next. An unexpected erased result type throws `.invalidSanitizedType(expected:actual:)`, never a force-cast trap. These errors carry type names, not command payloads.

Remove the misleading extension-only `validateAsync`, `sanitizeAsync`, sensitiveFields/updateSensitiveFields and capability-heuristic APIs. Migrate callers to the async requirements. Keep the distinct existing SecurityValidatable policy protocol and EncryptableCommand middleware protocol; do not silently change their contracts. Security sanitation remains application-defined transformation, not a universal injection defense.

### Ciphertext-only commands and atomic key identity

CommandEncryptor encrypts the complete Codable command. Its entry points become `encrypt<T: Command & Codable>(_: T) async throws -> EncryptedCommand<T>` and `decrypt<T: Command & Codable>(_: EncryptedCommand<T>) async throws -> T`. Use JSONEncoder/JSONDecoder and AES-GCM as already available. EncryptedCommand retains only `encryptedData: Data`, `keyIdentifier: String`, and `algorithm: String`; T is a phantom type. It has no originalCommand, closure, object reference or redacted shell. Its initializer accepts only these three fields. No plaintext reconstruction side channel remains.

Add public `EncryptionKeySnapshot: Sendable { let key: SendableSymmetricKey; let identifier: String }`. Replace KeyStore's separately read currentKey/currentKeyIdentifier requirements with `var currentKeySnapshot: EncryptionKeySnapshot? { get async }`, implemented atomically by each store. Keep key lookup and storage methods. CommandEncryptor caches a pair; each encryption captures one pair before suspension and returns that pair's identifier. Rotation stores and then publishes a complete pair. Remove the fallback identifier `default`. Shared-store rotations must not invalidate another encryptor's older still-stored key.

This deliberately changes the previous partial-field format. Migration requires decoding/re-encrypting with an old consumer while the original command and keys still exist; the old ciphertext may contain `{}` and cannot be claimed sufficient to recover lost plaintext. Do not log synthetic or real plaintext as migration evidence. This task does not repair the separate EncryptionMiddleware custom-result fallback SCP-09 or promise key-memory zeroization.

### Explicit cache identity

Require an explicit `any CacheKeyGenerator` on Cached, ConditionalCached, SimpleCachingMiddleware, CachingMiddleware and their convenience factories. Preserve the generic generator method `generateKey<T: Command>(for: T, context: CommandContext, middleware: String) async -> String`. Supply `ClosureCacheKeyGenerator` with an `@Sendable (any Command, CommandContext, String) async -> String` closure for ergonomic migration. Remove type-only, description-hash and Hashable.hashValue convenience key generation; no silent fallback.

Every implementation applies the same internal length-prefixed namespace encoding to command type, result type, cache/middleware type and the caller's key. The caller's key contract explicitly includes all result-varying command arguments, principal/tenant identity and relevant configuration/version. Correlation ID alone is not an identity key. Intentional sharing must be expressed by the caller's generator. Keep a String backend; do not pretend a hash value is equality or introduce a new persistent cache subsystem.

Clear old entries during migration because key format changes. Test all four public cache entry points with distinct arguments, principals, deliberately colliding Hashable values, separators and same-name types from distinct namespaces. Apply LRU weak predecessor ownership separately so clear, eviction and container destruction release multi-node values.

### Complete bounded decompression

`CompressionUtility.decompress(_:using:originalSize:maxOutputSize:)` gains a required positive `maxOutputSize: Int`. `originalSize: Int? = nil` is only an allocation hint, clamped to the limit and checked for invalid negative values. Decode incrementally until the platform stream signals completion. Return all output or throw; never return a prefix. Hitting the output limit before completion, invalid input, stalled progress, truncated input and trailing bytes after the single stream are errors. Limit equality is allowed when the stream completes at that size; probe completion without accepting an extra output byte.

Always release stream state and temporary buffers on every exit. Empty input remains empty for compatibility after validating arguments. The utility must not return unmarked raw input for small nonempty inputs: remove its small-input bypass so utility round trips for sizes 1–100 are meaningful. The middleware may still decide not to compress before invoking the utility. Existing misleading gzip/brotli aliases and ignored level remain SCP-08 follow-on work; describe the actual platform codecs in the new tests and do not claim external interoperability.

### Local boundary fixes

Truncation counts Swift Characters: nonpositive maximum returns empty; a suffix longer than the maximum is itself prefix-truncated; otherwise reserve suffix space. InMemoryAuditLogger capacity zero retains no events and counts dropped events; reject negative capacity at initialization with a documented precondition. Nil remains unbounded. ConsoleAuditLogger's production identity whitelist includes standard `userID`/`sessionID`, preserving existing legacy spellings if consumers use them. No sensitive-metadata whitelist expansion beyond these identity fields.

## Admission and policy

### One lease owner for the three bulkheads

Add a package-visible AdmissionGate actor to _ResilienceFoundation, used by BulkheadMiddleware, the legacy Bulkhead in ResilientMiddleware, and each partition. Its package-visible interface is:

```swift
package actor AdmissionGate {
    package init(capacity: Int, maxQueueSize: Int)
    package func tryAcquire(reserving: Int = 0) -> AdmissionLease?
    package func acquire(timeout: Duration? = nil) async throws -> AdmissionLease
}
package struct AdmissionLease: Sendable {
    package let wasQueued: Bool
    package let queueDuration: Duration
    package func release() async
}
package enum AdmissionError: Error, Sendable { case full, timedOut }
```

Capacity must be positive, queue size nonnegative, and reservation in `0...capacity`; wrappers validate configurations before constructing gates. A lease carries a private stable ID and owner. Release is idempotent at the owner. Active leases never exceed capacity. Queue occupancy is the number of owned pending waiters, not lifetime admissions. A release transfers an occupied slot to the first eligible waiter without exposing a free slot to a new arrival. Acquisition rechecks availability and installs its waiter in one actor turn, eliminating the partition's canQueue/install gap (R-A06, an adjacent audit note).

Each waiter ID is immutable before cancellation registration. Grant, cancel and timer expiry compete through the same actor-owned remove-before-resume transition. Cancellation before installation, after grant and during release must all settle exactly once; a cancelled recipient forwards or returns its lease. Cancel/timeout affects only that waiter. Queued timeouts can complete without waiting for unrelated active work. Active downstream timeouts still preserve handler/resource settlement.

`tryAcquire(reserving:)` checks and acquires atomically; donor borrowing cannot consume its configured reserve and does not jump an existing donor queue. Borrowed work releases the donor lease. Preserve existing reservation rounding and deprecated shared/tagged compatibility semantics. Wrappers await release on both success and error before returning; do not use unstructured defer tasks for normal release. Successful intentional fallback remains warning-suppressing (R-A01 adjacent constraint).

Ordinary and partitioned bulkhead queue timeouts share checked normalization: nil is unbounded; finite nonpositive values mean no queue wait; positive finite values must not exceed86,400seconds; nonfinite values are invalid. Validate once before conversion and cache the Duration. This conservative 24-hour policy is an explicit behavior break, not a Swift duration limit. Document it in migration/Breaking guidance; unbounded waiting with application cancellation does not preserve a longer finite built-in deadline. Extend the same boundary/probe matrix across both timed wrappers; legacy Bulkhead has no timeout option.

Use a package-only injected clock/sleeper seam for deterministic timer tests, plus production ContinuousClock defaults. The builder may choose the private waiter collection and exact timer seam signature, but must not replace the actor's single ownership rule with a task group around raw continuations.

### Health recovery

Age request history and recompute consecutive runs on every state/status query and health-check completion, using one injected `now` value per evaluation. Once fewer than minRequests remain, state comes from a fresh standalone check or becomes unknown; a check is fresh for at most `2 * checkInterval`. Unknown/degraded remain admitted under the existing block-only-unhealthy policy. Stale unhealthy history or a stale standalone check cannot permanently seal admission. Enough current healthy requests restore healthy status through the existing successThreshold policy; a fresh unhealthy standalone probe still blocks. A healthy probe need not override enough recent request failures to satisfy existing unhealthy criteria. Background monitor ownership R-F06 remains separate.

### Global rate scope and structural errors

Normalize the effective identifier inside RateLimiter, before every strategy's admission, status and reset lookup. `.global` uses a constant internal identity in a namespace distinct from every non-global scope; other scopes preserve the supplied identifier inside their own namespace. Distributed stores receive the normalized identity too: do not generate a per-instance UUID that splits an intended shared global budget. Separate logical distributed budgets require separate store namespaces. This change preserves the existing medium-priority behavior and reset limitations; R-F09/10 remain explicitly open, including distributed reset. Test all seven strategies with two caller identifiers and a shared budget; use a local store double for distributed strategy.

Add a package-visible ResilienceErrorClassifier in _ResilienceFoundation. Recognize the typed PipelineError timeout leaves (timeout, bulkheadTimeout, resilience(.timeoutExceeded), backPressure(.timeout)) structurally, before fallback descriptions, in both RetryMiddleware and selective CircuitBreakerMiddleware. Preserve explicit custom-policy overrides and the existing default unknown-error policy. Test producer × retry/breaker policy, including nested middleware execution, cancellation and foreign errors. Do not change retry total-budget or public HTTP-error policy in this task.

## Observability and measurement

### Transport lifecycle

UDPTransport owns every setup/send operation by stable ID. Network ready/failed/cancelled callbacks, timeout, task cancellation and close resolve an operation through one serialized terminal transition. Remove/disarm an operation before resuming its continuation; late and duplicate callbacks are ignored. A failed startup throws. Close marks the transport closed, settles pending operations, cancels Network resources and prevents a late ready callback from reviving the connection. There must be no task-group timeout waiting on an unresolved callback.

Use a small internal Network connection-driver protocol with a real adapter and deterministic scripted adapter. Keep MetricsTransport's send/sendBatch/close contract. Test real loopback ready→send→close in a separate process as well as scripted ready→cancelled, failed→cancelled, no-callback timeout, cancellation before registration and close during send. A send timeout/cancellation cancels and invalidates that connection, settles other pending operations with an error, and causes later sends to fail; StatsD can create a fresh transport. Retry only recoverable reported send failures, within the configured attempt count; never retry CancellationError or a closed connection. Validate port, finite positive timeouts and positive maxRetries on this touched route.

### One StatsD startup path

Remove the legacy NWConnection state machine and the useTransport switch. Both normal and injected StatsD construction use MetricsTransport. Keep `init(configuration: Configuration = .default)` synchronous and lazy. Provide `init(configuration: Configuration, transport: any MetricsTransport)` for injection and `start() async throws` for explicit startup validation. Concurrent batches share one owned startup task; each batch retains its data until readiness or a reported terminal error. Startup failures are observable through start and the configured error callback, not swallowed with try?. The next batch may start a new generation after failure; stale generations cannot replace a newer transport.

Add `close() async`: mark closed, cancel the flush timer/startup, settle connection work and discard buffered unsent records. Callers wanting delivery must forceFlush before close. Reject subsequent recording through the error callback. Close any transport produced by a startup that completed after closing. Do not claim UDP acknowledgement/delivery guarantees. Keep sampling and aggregation semantics unchanged; OBS-001/005/009 remain open. Test the default configuration (aggregation is disabled) and injected route, using multiple nonempty batches with maxBatchSize 1.

### Metrics configuration and flush

Replace the public unsafe mutable reference slots with a lock-protected configuration owner and public immutable `Metrics.Configuration: Sendable` containing storage, exporter and optional errorHandler. `Metrics.configure(_ configuration: Configuration) async` prepares the exporter callback and atomically replaces one complete snapshot. The configure(with:) convenience also becomes async. Keep `configure(with:)` and disable as safe convenience mutations; remove direct writable global fields and document migration. Read-only snapshot access is allowed. The host/port convenience builds the exporter and installs the same generation's callback before publishing it; callbacks are invoked outside locks. Custom recorders remain responsible for their own errors.

Each record/flush captures its complete configuration once before awaiting. An already started record may finish on the old generation; configuration replacement does not cancel/drain that generation. Flush drains the captured storage for local inspection and flushes its captured exporter, without recording the drained items a second time. Add `FlushableMetricRecorder: MetricRecorder { func flush() async }`; StatsD's public flush forwards to forceFlush, and existing internal flush becomes flushBuffer. Flush is not a barrier for concurrent records or a flush of retired exporters; callers needing that guarantee quiesce producers and flush the old snapshot explicitly.

Typed timer values convert seconds to milliseconds exactly once, matching MetricSnapshot. Pool latency nanoseconds include whole seconds plus fractional attoseconds, clamp negative durations to zero and saturate at UInt64.max on overflow. Test subsecond, one-second, multisecond and overflow boundaries without wall-clock sleeps.

## Validation repairs and closure

Repair the observed Release throughput-test site and any mechanically located equivalent conversions so work has observable results and timing uses ContinuousClock; never convert a nonfinite rate to Int. Preserve the functional assertions and keep actual performance claims in Release benchmark validation. Rewrite all five vacuous cancellation cases with an acknowledged cancellation point and a returned assertion/reached-state result checked by the parent. Reuse TestSynchronizer only with explicit fixture cleanup; it is not a hard watchdog.

CapturingEmitter must reject missing and wrongly typed expected properties. run-tests.sh must propagate every selected Swift test exit code, honor filter/target arguments, discover all non-performance test targets by default (including TestSupport), and never infer success from an empty NONE run or grep output. Trivy findings at configured HIGH/CRITICAL severities must fail the security job; the aggregate status must fail unless this required job succeeds. Do not claim external branch protection was configured.

The implementation handoff requires a closure table for all 37 IDs: source change, test name, old behavior evidence, new result, configuration/platform, independent challenge for the 17 high-impact IDs, and any limitation. Use separate commits per reviewable task and never fold unverified findings into a blanket “all fixed.” A source-only original finding can close through a clearly stated invariant plus adversarial regression; never relabel it as a baseline runtime reproduction.

## Choices delegated to the implementer

Private data structure names, small test helper layout and exact lock implementation may follow existing repository style. The contracts, public signatures above, affected finding IDs, required schedules and release compatibility decisions are fixed by this design. If compilation establishes that a proposed private/package interface needs adjustment, document the equivalent invariant in the closure record rather than silently weakening it.
