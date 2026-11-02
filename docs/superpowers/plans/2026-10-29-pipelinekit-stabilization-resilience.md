# PipelineKit resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore permit conservation, recoverable health admission, global rate budgets and timeout policy classification.

**Architecture:** Share an actor-owned lease gate across the three bulkhead implementations. Keep health evaluation current and normalize policy inputs before strategy-specific execution.

**Tech Stack:** Swift 6.2, actors, XCTest, ContinuousClock, existing _ResilienceFoundation/_ResilienceCore/_CircuitBreaker/_RateLimiting targets.

**Spec:** [Stabilization design](../specs/2026-10-29-pipelinekit-stabilization-design.md), “Admission and policy.”

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

1. Cancellation can happen before waiter registration or immediately after grant: R01 owns both schedules and lease forwarding.
2. Fresh arrivals can steal a released slot while an older waiter wakes: R02/R03 assert peak live handlers, not only final counters.
3. A timeout must affect one waiter without orphaning siblings: R03 checks terminal outcomes and joins every child.
4. A healthy request may never arrive if stale health state blocks it: R04 advances a controlled clock without recording another request.
5. Global scope must survive every strategy and structural error policy must survive actual producers: R05/R06 use full tables, not string-only unit tests.

## Task R01: Introduce an owned admission lease primitive

**Finding ownership:** Shared prerequisite for R-F01/02/03/04/15; closes no wrapper finding alone. **Dependencies:** V01.

**Files:** Create `Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift`, `Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift`, `Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift`. Modify `Package.swift` only to add direct _ResilienceFoundation, _CircuitBreaker and _RateLimiting test dependencies if required for package/internal test seams; do not change product dependencies or settings.

**Interfaces:** Produce AdmissionGate, AdmissionLease and AdmissionError exactly as specified in the design. Add package `snapshot() -> AdmissionSnapshot` with `active: Int` and `queued: Int` for state/metrics inspection. Package testing initializer additionally accepts `now: @Sendable () -> Duration` and `sleep: @Sendable (Duration) async throws -> Void`; production initializer uses ContinuousClock relative to a fixed origin. Lease IDs/owner remain private.

- [ ] Add `testLeaseConservationMatrix` for capacities 1/2, queue sizes 0/1/3, repeated waves and duplicate release. Assert 0≤active≤capacity, queued equals pending waiter ownership, and both counts zero after all work joins.
- [ ] Add `testCancellationRegistrationAndGrantRaces`, `testTimeoutRemovesOnlyItsWaiter`, `testReservedAcquisitionIsAtomic`. Acknowledge actual registration before advancing time; also cancel before registration and after grant. Assert each operation has exactly one terminal result, grants/releases balance, siblings proceed, and a full queue rejects rather than overwrites.
- [ ] Run `swift test --filter AdmissionGateContractTests`; expected compile red until the primitive exists. This does not reproduce the old wrapper defects by itself.
- [ ] Implement FIFO actor-owned waiter and active-lease records, remove-before-resume arbitration, idempotent release and no-suspension handoff. An acquire rechecks availability and installs its waiter in one actor turn. Check cancellation before installation and after grant; return/forward a just-granted lease before throwing CancellationError. Cancel timer ownership on every terminal transition; validate numeric inputs before conversion.
- [ ] Run the same filter in Debug and Release. Expected deterministic state and terminal-result assertions pass. Confirm no timer/raw-continuation task group can hold timeout delivery hostage.
- [ ] Record this prerequisite without marking wrapper findings closed; commit `feat(resilience): add actor-owned admission leases`.

## Task R02: Migrate ordinary and legacy bulkheads

**Finding IDs:** R-F01, R-F15. **Adjacent constraint:** R-A01 successful fallback warnings. **Dependencies:** R01; C05 for final diagnostic integration.

**Files:** Modify `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift`, `Sources/PipelineKitResilienceCore/ResilientMiddleware.swift`. Extend `Tests/PipelineKitResilienceTests/BulkheadMiddlewareTests.swift`, `Tests/PipelineKitResilienceTests/ResilientMiddlewareTests.swift`, `Tests/PipelineKitResilienceTests/NextGuardSuppressionConformanceTests.swift`. Create `Tests/PipelineKitResilienceTests/BulkheadAdmissionConservationTests.swift`.

**Interfaces:** Consume AdmissionGate.tryAcquire/acquire and AdmissionLease.release. Preserve public BulkheadMiddleware/legacy Bulkhead execution APIs and queue metadata/metrics; legacy maxWaitingCalls maps to gate maxQueueSize, and `getStats() async -> BulkheadStats` awaits the gate snapshot instead of maintaining a second active counter; map AdmissionError.full/timedOut to the existing wrapper PipelineError cases. Cancellation propagates as CancellationError. Queue timeout applies while waiting, not to arbitrary handler settlement.

- [ ] Add `testQueueBudgetIsReusableAcrossAcknowledgedWaves`: run more contended waves than maxQueueSize and assert every legitimate wave can queue, including success, throw, queued cancel and timeout. Assert queue occupancy returns to zero.
- [ ] Add `testLegacyHandoffNeverExposesCapacityToNewArrival`: capacity=1, queue B behind A, release A and race fresh C with B. Peak simultaneously entered handlers must remain 1; both complete after explicit gates. Repeat capacity=2 and count conservation. Use the same harness for both wrappers.
- [ ] Add fallback/custom successful-return and wrong-result-type/error cases through an actual guarded pipeline. Confirm intentionally successful short circuits emit no never-called warning in both chain representations while accidental omission still warns.
- [ ] Run `swift test --filter BulkheadAdmissionConservationTests` under the external watchdog; expect queue-wave red and/or source-invariant failure. Do not assert the legacy non-FIFO interleaving was forced unless the trace proves it.
- [ ] Replace the separate QueuedCommands and legacy count/raw-continuation ownership with AdmissionGate. Preserve fail-fast, queue, fallback and custom policy selection. Await lease release in explicit success/catch paths; reserve capacity during transfer. Restore NextGuardWarningSuppressing conformance for valid successful fallback.
- [ ] Run the new filter plus `swift test --filter 'BulkheadMiddlewareTests|ResilientMiddlewareTests|NextGuardSuppressionConformanceTests'`. Expected all fixture work settles, peak concurrency bound holds and deprecated tagged mode remains intentionally shared.
- [ ] Update both finding rows and the R-A01 constraint note; commit `fix(bulkhead): conserve admission across queues and handoffs`.

## Task R03: Migrate partition queues, cancellation and borrowing

**Finding IDs:** R-F02, R-F03, R-F04. **Adjacent constraint:** R-A06 atomic waiter installation. **Dependencies:** R01 and R02; extend and run R02's shared class harness here too.

**Files:** Modify `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift`. Create `Tests/PipelineKitResilienceTests/PartitionedBulkheadAdmissionTests.swift`; extend `Tests/PipelineKitResilienceTests/PartitionedBulkheadConfigurationTests.swift` and `Tests/PipelineKitResilienceTests/BulkheadAdmissionConservationTests.swift` (add the partitioned wrapper to R02's shared matrix). Extend `Tests/PipelineKitResilienceTests/BulkheadMiddlewareTests.swift` for the shared timed-wrapper boundary/probe rows and `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/r02_timeout_validation.py` to select ordinary/partitioned validation probes; preserve existing raw evidence.

**Interfaces:** Each partition owns AdmissionGate and returns AdmissionLease. Replace the private queued acquisition closure/release-closure protocol with a lease-bearing result; consume `tryAcquire(reserving: Int)` for a donor and `acquire(timeout: Duration?)` for local queuing. Preserve existing public partition selector, metrics and reservedCapacityPercentage/maxBorrowPercentage alias semantics.

- [ ] Add `testQueuedHandoffTransfersOneLease`: capacities 1/2, repeated handoffs, success and throw; exactly one lease per active handler, no phantom occupancy.
- [ ] Add `testTimedOutWaiterDoesNotWaitForHolderOrOrphanSibling`: hold A and install B; advance the injected clock before installing C so the same partition timeout gives C a later deadline. Advance to B's deadline while A remains held. B returns timeout before A releases; C stays pending, then enters after A releases before C's deadline. Join A/B/C and assert final active/queued zero. Add cancelled B with an untimed sibling under a nil-timeout partition, and post-grant cancellation variants. A public partition has one queueTimeout for all waiters; do not invent per-command timeout policy to create a timed/untimed pair. R01 separately covers mixed timeout policies at the gate level.
- [ ] Add `testDonorReserveAndQueuePriorityAreAtomic`: two borrowers race for the final borrowable donor slot. Assert reserve remains intact, at most one borrower succeeds, donor-owned queued work is not bypassed, and releasing borrowed work restores the donor. Exercise borrowing enabled/disabled and alias configurations.
- [ ] Run `swift test --filter PartitionedBulkheadAdmissionTests` under the watchdog. Expected old code fails conservation or timeout/sibling settlement; capture exact outcome and do not leave blocked tasks in the test runner.
- [ ] Remove duplicate increment and raw waiter arrays/task-group timeout. Make queue selection/installation one gate operation. Borrow using atomic reservation acquisition, preserve established reserve rounding, and release the returned donor/local lease exactly once before wrapper return. Reuse R02's internal checked queue-timeout normalization and its documented86,400-second positive maximum; extend the shared boundary matrix to both timed wrappers (ordinary and partitioned), with finite extreme negatives normalized to no-wait, and no legacy-timeout claim.
- [ ] Run the new filter, configuration tests and the full BulkheadAdmissionConservationTests matrix with all three wrappers. Expected active-work/count equality and eventual settlement in every tested schedule.
- [ ] Update three rows plus R-A06 note; commit `fix(bulkhead): own partition waiters and reserve donor capacity atomically`.

## Task R04: Re-evaluate health from current evidence

**Finding ID:** R-F07. **Dependencies:** V01.

**Files:** Modify `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift`. Add `Tests/PipelineKitResilienceTests/HealthRecoveryContractTests.swift`; retain existing `HealthCheckMiddlewareTests.swift`.

**Interfaces:** Add an internal middleware initializer taking `now: @escaping @Sendable () -> Date`, passed to HealthMonitor/ServiceHealthStats, and an internal `startPeriodicHealthChecks: Bool = true` scheduling seam. The unchanged public initializer always enables periodic checks; deterministic recovery/probe tests may disable only automatic scheduling and await on-demand checks. Preserve existing health/check tests and source-trace public/default automatic scheduling; automatic monitor lifecycle is not runtime-verified or repaired by this task. Evaluation and status construction use a single captured Date. Keep public health state/status types.

- [ ] Add `testBlockedServiceRecoversWhenFailureWindowExpires`: minRequests=1, failureThreshold=1, blockUnhealthyServices=true; one failed request blocks the next. Advance beyond windowSize without recording new requests, query each status API, then assert unknown allows a new successful handler entry.
- [ ] Add `testFreshUnhealthyProbeStillBlocksAndStaleProbeDoesNot`, boundary freshness tests at 2×checkInterval, and minRequests=10 control. Pin that a fresh healthy probe need not override enough recent failed requests; once stale evidence expires, normal admission resumes. Check successThreshold while an unhealthy state still has sufficient current samples.
- [ ] Run `swift test --filter HealthRecoveryContractTests`; expected current stored/pruned-on-record-only behavior fails recovery.
- [ ] Prune history and recompute consecutive suffix runs on every evaluation, including state/status queries and probe completion. Use only fresh standalone probe status when current requests are insufficient; otherwise unknown. Avoid carrying a historical unhealthy latch after evidence expires. Preserve block-only-unhealthy and state-change notification behavior.
- [ ] Run the filter plus HealthCheckMiddlewareTests. Expected no wall-clock sleeps in recovery tests and no requirement for a blocked downstream request to reset state.
- [ ] Update R-F07; leave monitor lifecycle R-F06 and broader classification policies open; commit `fix(health): expire stale evidence before admission decisions`.

## Task R05: Enforce global identity before rate strategy dispatch

**Finding ID:** R-F08. **Dependencies:** none beyond validation setup.

**Files:** Modify `Sources/PipelineKitResilienceRateLimiting/RateLimiter.swift` and its `Algorithms/TokenBucket.swift`, `Algorithms/SlidingWindow.swift`, `Algorithms/FixedWindow.swift`, and `Algorithms/LeakyBucket.swift` only for internal clock injection. Create `Tests/PipelineKitResilienceTests/RateLimitScopeContractTests.swift`; use a test-local DistributedRateLimitStore actor.

**Interfaces:** Add private `effectiveIdentifier(_ supplied: String) -> String` and use it in allowRequest/getStatus/reset paths. Encode global and non-global scopes into distinct namespaces. The global component is constant, not UUID-based; two distributed limiters sharing the same intended store budget see the same global identity. Add an internal RateLimiter initializer accepting `now: @escaping @Sendable () -> Date` and pass it to internal initializers of the four algorithms for deterministic boundary checks. Public constructor signatures and Date-based defaults remain unchanged; preserve algorithm/refill/reset policy and cover all affected clock paths with the strategy/boundary matrix plus any existing algorithm tests actually present.

- [ ] Add `testScopeByStrategyMatrix`: tokenBucket, slidingWindow, fixedWindow, leakyBucket, adaptive, distributed and priorityBased. Give each a budget of one in a non-refilling test interval (adaptive baseRate=1/load=1 (capacity = baseRate × (2−load) = 1) and priority medium limit=1); global identifiers A then B yield true,false. PerUser/perIP/perCommand supplied distinct identifiers retain separate budgets. A repeated identifier is rejected according to each strategy.
- [ ] Add `testGlobalStatusUsesSameEffectiveKey`, `testGlobalDistributedInstancesShareStoreIdentity` and local reset controls. Record the distributed store's exact keys; ensure user-supplied strings cannot collide with the global namespace. Do not assert broken distributed/priority reset behavior is fixed in this task.
- [ ] Run `swift test --filter RateLimitScopeContractTests`; expected global A/B sharing red, consistent with V300.
- [ ] Normalize identity once at each public policy entry, before every strategy branch; retain strategy cost/rate/priority rules. Update distributed counter migration guidance because internal keys change. Distinct logical distributed budgets must use separate store namespaces.
- [ ] Re-run the matrix with explicit near-window boundary controls. Expected all seven strategies share the global budget; R-F09 and R-F10 remain explicitly deferred in the closure note.
- [ ] Update R-F08; commit `fix(rate-limit): apply global scope consistently across strategies`.

## Task R06: Classify PipelineKit timeouts structurally

**Finding ID:** R-F21. **Dependencies:** none beyond validation setup.

**Files:** Create `Sources/PipelineKitResilienceFoundation/Errors/ResilienceErrorClassifier.swift`, `Tests/PipelineKitResilienceTests/ResilienceErrorPolicyTests.swift`. Modify `Sources/PipelineKitResilienceCore/RetryMiddleware.swift`, `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift`. Retain existing retry/breaker probe-accounting tests.

**Interfaces:** Package `ResilienceErrorClassifier.classifyPipelineError(_ error: any Error) -> PipelineFailureCategory?`; category cases `timeout`, `cancelled`, `other`. Return nil for foreign errors, so existing explicit RetryableError/CircuitBreakerError/URLError/custom rules remain applicable. PipelineError.timeout, bulkheadTimeout, resilience(.timeoutExceeded) and backPressure(.timeout) map to timeout independent of their descriptions; other PipelineError cases cannot become timeouts because a payload string contains “timeout”. Treat `PipelineError.wrapped` and `retryExhausted` as `other` without description fallback or recursive unwrapping. An unchanged-policy wrapped control may wrap `PipelineError.timeout` (whose old description uses "timed out"); separately pin removal of literal-"timeout" payload coercion and preserve foreign-wrapper fallback. Preserve ordinary typed cancellation as retry=false and breaker governed by unknown, while native CancellationError keeps existing evaluator precedence; context text cannot turn typed cancellation into timeout. Document the removed payload-text coercion as a behavior change and direct application-specific unwrapping to custom evaluators.

- [ ] Add `testTimeoutProducerByPolicyMatrix`: every typed timeout leaf (PipelineError.timeout, bulkheadTimeout, resilience(.timeoutExceeded), backPressure(.timeout)), actual TimeoutMiddleware throw, URLError.timedOut and an explicit wrapped-error control with its existing policy. Do not introduce recursive arbitrary-error unwrapping. With two total retry attempts, the first timeout followed by success calls the handler twice. Timeout-only breaker with threshold=1 opens after one counted timeout and rejects the next handler entry.
- [ ] Add negative controls for cancellation, validation whose description contains “timeout”, foreign unrelated error, default breaker unknown behavior and explicit custom overrides. Assert handler counts, exact state and surfaced error policy, not just classification helper return values.
- [ ] Run `swift test --filter ResilienceErrorPolicyTests`; expected own-timeout retry/selective-breaker red; V301 supplies prior retry evidence.
- [ ] Add enum-first handling through the package helper in both consumers. Preserve custom override precedence and existing policy for non-timeout categories; do not expand wrapper-unwrapping or change retry budget semantics silently. Document any intentional cancellation mapping in the matrix.
- [ ] Run the filter plus `swift test --filter 'RetryMiddlewareTests|CircuitBreakerMiddlewareTests|AuditCircuitBreakerProbeWedgeTests|CircuitBreakerProbeAccountingTests'`. Expected structural timeout cases pass and previous half-open protection remains.
- [ ] Update R-F21; commit `fix(resilience): classify pipeline timeouts before error descriptions`.

