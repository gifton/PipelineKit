# Core stabilization behavior changes

These follow-up fixes extend the [first stabilization batch](first-stabilization-batch.md).
They are intended for the next minor release; no version or tag is selected here.
Public method signatures and the Swift 6.2 / platform 26 minimums are unchanged.

## Admission deadlines and capacity

`ConcurrentPipeline` now applies `PipelineOptions.backPressureStrategy.error(timeout:)`
to ordinary execution. Previously that configured admission deadline was ignored.
The explicit `execute(_:context:timeout:)` overload overrides the configured deadline.
Both deadlines cover waiting for admission; an admitted handler owns its capacity until
it finishes or throws, including when cancellation is not immediately observed.

The accepted timeout values match the bulkhead policy:

- `nil` means no admission deadline, subject to the strategy's capacity rejection rules.
- Finite nonpositive values permit immediate admission only.
- Positive values must be finite and no greater than 86,400 seconds (24 hours).
- NaN, either infinity, and larger positive values fail a configuration precondition.

Check configurations that previously supplied ignored, nonfinite, or longer deadlines.
Using `nil` with application-managed cancellation is an unbounded wait, not an equivalent
replacement for a longer finite deadline. Existing back-pressure timeout and queue-full
error cases are retained.

Nil `PipelineOptions.maxConcurrency` and `maxOutstanding` now mean unlimited, including
the `.unlimited()` preset. A finite outstanding bound still applies when concurrency is
unlimited. Existing strategy-specific queue policies remain in effect.
`PipelineCapacityStats.maxOutstanding` preserves nil; its nonoptional `maxConcurrency`
uses `Int.max` to represent unlimited, and utilization is zero for unlimited concurrency.

Pipeline options no longer inherit the semaphore's separate five-minute stale-waiter
cleanup. Direct callers of the public `BackPressureSemaphore` initializer retain its
legacy `waiterTimeout` parameter and default, and its nil outstanding limit still defaults
to ten times concurrency. This is separate from the pipeline options contract.

Regression coverage is in `AdmissionCancellationContractTests`. The isolated invalid-input
probe is documented in the [validation tools](../../Scripts/validation/README.md).

## Automatic security validation

Strict reflection-based `SecurityPolicyMiddleware` validation now charges supported leaves
in arrays, nested values, present optionals, and inherited stored fields. Commands that
previously bypassed size or string restrictions through these shapes may now be rejected.

The size estimate measures logical reflected content: String UTF-8 bytes, Data bytes, and
`MemoryLayout<Any>.size` per supported scalar. Supported scalars are Bool, Int/UInt and their
8/16/32/64-bit variants, Float, Double, UUID, and Date. Container overhead and absent optionals
contribute zero. Opaque leaves and content hidden by custom mirrors are not measured.
This estimate is neither a serialized size nor a process-memory budget.

Repeated acyclic references count once per occurrence. Reflected reference cycles now fail
with the existing security-policy validation-failed error. Commands with intentional cycles
can implement `SecurityValidatable`; that validator takes precedence and must enforce the
application's complete policy. The existing non-strict reflection bypass is unchanged.

Size validation stops at the first excess. The error reports the observed sum rather than
the size of unvisited content; an overflowing sum rejects and reports `Int.max`. Traversal
uses an explicit stack, with deep-container and inherited-field regression coverage in
`SecurityPolicySizeTests`.

## Rate-limit cleanup

Token-bucket and sliding-window cleanup retain live state when an admission or reset occurs
during an awaited child read. No configuration migration is required. The forced interleaving
tests are in `RateLimiterCleanupTests`; scope behavior remains covered by
`RateLimitScopeContractTests`.
