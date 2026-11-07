# Preparing for 0.6.0

0.6.0 is the planned next minor release. The changes below remain under
Unreleased; the latest published tag is 0.5.4. Evaluate these changes with a
local package checkout until a qualified 0.6.0 tag is available. Keep production
dependencies on `"0.5.4"..<"0.6.0"` while completing migration.

## Caller changes

Read the [first stabilization migration](first-stabilization-batch.md) and its
linked security, telemetry, error, lifecycle, and resilience follow-ups. The
[release qualification migration](release-qualification.md) adds three changes
that must also be included in an upgrade from 0.5.4:

- Use `try await` for `RateLimiter.getStatus` and
  `SecureCommandDispatcher.getRateLimitStatus`; backing-store failures and
  cancellation propagate to the caller.
- Configure middleware mocks with both middleware and command types through
  `PipelineTestUtils.createTestPipeline`. Delay and failure configuration now
  throws on invalid settings. An arbitrary wrapped pipeline only records
  execution and rejects interception configuration.
- Remove `MemoryProfiler`, its related report types, `MemoryPattern`, and
  `memoryProfiler`. No replacement allocation-profiler API is provided.

The compatibility APIs deprecated in 0.5.4 are removed:

| Removed API | Replacement |
| --- | --- |
| `BulkheadMiddleware.IsolationMode.tagged` | `PartitionedBulkheadMiddleware` with declared partitions and `allowBorrowing: false` for separate capacity. Use `.semaphore` when one shared limit is intended. |
| `Configuration.maxBorrowPercentage` and its initializer parameter | `reservedCapacityPercentage`; the value still means the lender's reserved, non-lendable fraction. |

The tagged mode's automatic `bulkheadTag` metadata is removed with that mode.
Applications needing a diagnostic tag should write it explicitly. The
[partition example](../guides/resilience-patterns.md#multi-tenant-workloads)
shows the replacement extractor, which receives command and context.

## Rate state and time

An identity idle for 300 seconds no longer receives a fresh budget automatically.
Cleanup retains state whenever recreation would change admission decisions.
This matters for windows longer than five minutes, slow refill, and zero refill.
Explicit `reset(identifier:)` resets one identity; `reset()` resets all budgets.

The first admission into an empty leaky bucket starts a new leak interval.
Fractional phase is retained while the bucket is occupied. With capacity 1 and
interval 10 seconds, an admission into an empty bucket at time 16 cannot admit
again at 20; it can at 26. `RateLimiterEvictionContractTests` compares retained
and reclaimed state for this boundary.

Local algorithms share a nondecreasing logical clock. Wall-clock rollback freezes
policy time until it catches up, so rollback cannot restore expired history or
mint quota. Distributed stores retain their own clock and expiration contract.
Adaptive token buckets retain their original capacity even when load changes.
Their identity state, and depleted zero-refill state, may remain resident until
explicit reset. No identity-count cap discards active budgets.

## Context callbacks

No caller changes are required. Context descriptions, metadata getters, and
retired-value destruction execute outside the context storage lock.
`CommandContextCallbackTests` covers reentry through descriptions, both snapshot
forms, and clear; `CommandContextRetirementTests` covers retired-value callbacks.
Snapshot storage capture is atomic, but callbacks may subsequently mutate the
context. A snapshot is not a transaction across arbitrary user-supplied getters.

## Qualification and remaining evidence

Tags invoke the same qualification workflow as pull requests. Debug and Release
correctness, numeric boundaries, compression interoperability, all documented
public-consumer modes, and telemetry wire checks must pass. Publication also
requires an exact nonempty changelog section and a built documentation artifact.
See [validation commands](../../Scripts/validation/README.md).

Health error classification and recovery from issue #87 are already implemented.
`ResilienceErrorPolicyTests.testDomainAndAdmissionErrorsDoNotScoreHealthOrDefaultBreaker`
and `testHealthCustomEvaluatorOverridesOnlyNoncancellationErrors` exercise the
classification rules; `HealthRecoveryContractTests.testBlockedServiceRecoversWhenFailureWindowExpires`
exercises recovery without a new admitted request. Remote issue status is separate
from this source-level evidence.

Before selecting the dated release section, review the actual CI run, platform
results, test skips, and benchmark comparison. The
[qualification skip inventory](release-qualification.md#qualification-boundaries)
and [platform matrix](../platform-support.md) distinguish evidence from declared
support. Local host passes do not establish simulator/device or Swift compiler
floor qualification. These changes do not complete a dashboard, general-purpose
allocation profiler, or backpressure's built-in rate-limiting integration.
