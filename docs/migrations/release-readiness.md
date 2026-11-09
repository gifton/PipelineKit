# PipelineKit 0.6.0 release readiness

0.6.0 is the release target, with notes in the dated
[CHANGELOG section](../../CHANGELOG.md#060---2026-11-07). It is a minor release
because the changes below break source compatibility under [VERSIONING.md](../../VERSIONING.md).
The prepared notes do not establish publication; check the
[releases page](https://github.com/gifton/PipelineKit/releases) for the tag.

Evaluate with a local package checkout until a qualified `v0.6.0` tag is available.
The migration baseline is `"0.5.4"..<"0.6.0"`; after migration and publication,
use `"0.6.0"..<"0.7.0"` to stay within the new minor series. Swift 6.2 and
Apple OS 26 deployment floors are unchanged.

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

Before tagging the release commit, review its actual CI run, platform results,
test skips, and benchmark comparison. The
[qualification skip inventory](release-qualification.md#qualification-boundaries)
and [platform matrix](../platform-support.md) distinguish evidence from declared
support. Local host passes do not establish simulator/device or Swift compiler
floor qualification. These changes do not complete a dashboard, general-purpose
allocation profiler, or backpressure's built-in rate-limiting integration.

## Qualification snapshot

This snapshot was reviewed on 2026-11-07 (America/Los_Angeles). It records the
evidence used to prepare 0.6.0; the release commit still requires its own checks.

- [PR #116](https://github.com/gifton/PipelineKit/pull/116), head
  `f105f8ddaca32f408571cbb9c9902d022c891287`, merged as
  `a0d7c8ff0ef08f529fd994387fe9950affc67251`. Those revisions have identical trees.
  The [PR qualification run](https://github.com/gifton/PipelineKit/actions/runs/42449358486)
  passed, and [post-merge CI](https://github.com/gifton/PipelineKit/actions/runs/42452021452)
  passed on `a0d7c8f`.
- The PR qualification logs report 1,523 selected macOS Debug test executions
  with six skips, 1,520 Release executions with six skips, and 1,554 iOS
  simulator executions with 39 skips; each reported zero failures. Skips are
  not passes. The iOS run used iOS 26.5; the main lanes used Xcode 26.6.
- Swift 6.2/Xcode 26.0.1 compiled package and consumer tests in both configurations.
  tvOS, visionOS, and advisory watchOS jobs built Debug and Release simulators.
  These build-only results do not establish runtime or device qualification.
- All five current examples executed with verified success markers in Debug
  and Release. The [historical caller rehearsal](examples-rehearsal.md) covers
  unchanged v0.5.4 examples against both library revisions and states its limits.
- The [specialty report](https://github.com/gifton/PipelineKit/actions/runs/42449358483)
  succeeded with its four substantive jobs skipped. It supplies no additional
  performance, memory, stress, or security qualification.

### Admission performance advisory

The [initial hosted comparison](https://github.com/gifton/PipelineKit/actions/runs/42285019405)
and [repeat](https://github.com/gifton/PipelineKit/actions/runs/42286463516) reported
admission median ratios of **1.178** and **1.143**. Both compared baseline
`1ed3f1e9ee23f9f7aa21c34085fe8e6abd995154` with candidate
`8e19b39667180ff3db0a76133c2fbbb169d50783`. The candidate's measured-source,
harness, and root dependency-lockfile fingerprints match `a0d7c8f`. The baseline
is the pre-runtime-correction revision, not the v0.5.4 release.

A bounded local Release comparison of that baseline and `a0d7c8f` on 2026-11-07
used prebuilt binaries in the fixed sequence `B B | A B | B A | A B | B A | B B`.
All 12 processes passed the workload checks. Each workload used five warmups
and 40 measured batches of 1,000 operations. The four admission candidate/baseline
median ratios were **0.9990, 0.9818, 0.9953, and 0.9840**, with median **0.9896**.
Same-binary control ratios were **1.0099** and **1.0004**. These are batch timing
observations from four process pairs, not individual-request percentiles or a
statistically established speedup.

Local endpoint observations showed AC power, nominal thermals, and Low Power Mode
off. The Mac15,9 host used Swift 6.4.2 and macOS 27.0.1, unlike the Swift 6.3.3
hosted runners. Its required 85% aggregate idle condition was not met within
the fixed settling budget. The local comparison therefore does not clear the
hosted advisory or establish battery state as its cause. No optimization or
profiling followed that stop decision; allocation evidence remains unavailable.

The hosted slowdown remains unexplained and nonblocking under the
[benchmark policy](../benchmarks.md). Correctness failures and invalid benchmark
records remain fatal. Any follow-up comparison must pin both revisions explicitly:
the manual specialty workflow's default baseline is current main.

## Publication prerequisites

1. Merge the reviewed preparation PR and qualify the intended release commit,
   including the consumer's aligned runtime dependency pins.
2. Confirm exactly one nonempty dated `[0.6.0]` section and extract it with
   `python3 Scripts/ci/release_notes.py --tag v0.6.0 --output /tmp/release-notes.md`.
3. Verify shared qualification and the documentation build for the tagged commit.
   The release workflow requires both before creating the release and publishing docs.

Creating or pushing `v0.6.0` triggers publication; preparation alone does not do so.
