# Resilience policy contracts

0.6.0 changes retry admission, timeout configuration, rate-limit routing/reset,
and overload policy. See the [release-readiness guide](release-readiness.md).
The existing cooperative
settlement contract remains: deadlines do not preempt arbitrary handlers, and admitted
work keeps its resources until it settles.

## Retry budgets and HTTP status extraction

`RetryMiddleware.Configuration.maxRetryTime` is a monotonic budget measured from
execution entry. It controls admission of the initial attempt, later attempts, and
backoff. Nil disables the time budget; zero admits no attempt. `maxAttempts` continues
to count retries in addition to the initial attempt.

Backoff is limited to the remaining budget. The middleware rechecks the budget after
policy/event callbacks before beginning more work. A handler admitted before expiry
can complete afterward: success is returned, and a failure keeps its original identity
without another retry. Exhaustion before any attempt throws
`RetryError.maxRetryTimeExceeded`; after a failure it returns that last error.
Callback or handler work that does not return can delay settlement beyond the budget.

```swift
import PipelineKitResilience

let budgetedRetry = RetryMiddleware(configuration: .init(
    maxAttempts: 2,
    strategy: .fixed(delay: 0.1),
    maxRetryTime: 0.25
))
_ = budgetedRetry
```

The HTTP factory now requires a status-code extractor. Its former private error type
could not be supplied by consumers. Adapt application or transport errors explicitly:

```swift
import PipelineKitResilience

struct ServiceHTTPFailure: Error {
    let statusCode: Int
}

let httpRetry = RetryMiddleware.forHTTPStatusCodes([429, 502, 503]) { error in
    (error as? ServiceHTTPFailure)?.statusCode
}
_ = httpRetry
```

An unknown or unlisted status does not retry. Native `CancellationError` and
`PipelineError.cancelled` bypass the extractor and all retry predicates.

## Timeout configuration and grace outcomes

Remove `cancelOnTimeout:` and `gracePeriodBackoff:` from timeout configuration.
Both were ignored. Replace the adaptive-grace initializer with an explicit fixed
grace period:

```swift
import PipelineKitResilience

let timeoutPolicy = TimeoutMiddleware(configuration: .init(
    defaultTimeout: 2,
    gracePeriod: 0.25
))
_ = timeoutPolicy
```

The initial deadline begins a configured grace period; expiry requests cooperative
cancellation and waits for owned work to settle. A zero grace period requests
cancellation at the initial deadline. Grace recovery is recorded from the outcome of
that invocation, so sequential and concurrent executions do not share tracker state.
A suspended grace notification cannot postpone the grace deadline. The notification
remains owned work and is cancelled/joined when its scope ends.

Caller cancellation and timeout-owned expiry are separate outcomes. Preserve handler
error identity when settling caller cancellation; a deadline that wins retains its
timeout outcome while joining the losing operation. Neither a slow handler nor a slow
diagnostic callback is a hard wall-clock bound on return.
Handler-originated `TimeoutError` values, including nested timeout failures, retain
their original case and payload without triggering the outer timeout diagnostics.

Standalone `GracePeriodBackoff` remains a duration calculator. It does not configure
`TimeoutMiddleware`. Existing fixed-grace, per-command timeout, resolver, and timeout
handler APIs remain available.

## Rate-limit priority and reset

`RateLimiter.allowRequest`, `getStatus`, and keyed `reset` accept a priority that
defaults to `.medium`. `EnhancedRateLimitingMiddleware` passes its extracted priority
to both admission and rejection-status lookup. For `.priorityBased`, each configured
priority has its own budget; a missing priority is denied with zero limit/remaining.
Other rate strategies retain their existing cost and admission policies.

Reset is now `async throws`. Add `try` to existing calls:

```swift
import PipelineKitResilience

let priorityLimiter = RateLimiter(strategy: .priorityBased(limits: [
    .medium: .init(maxRequests: 10, windowSize: 60),
    .high: .init(maxRequests: 20, windowSize: 60)
]))
_ = try await priorityLimiter.allowRequest(identifier: "customer", priority: .high)
let highStatus = try await priorityLimiter.getStatus(identifier: "customer", priority: .high)
try await priorityLimiter.reset(identifier: "customer", priority: .high)
try await priorityLimiter.reset()
_ = highStatus
```

Keyed reset uses the same effective scope and priority key as admission/status. Nil
identifier clears every local identifier and priority. In global scope, identifiers
refer to the shared budget. The existing distributed key namespaces are unchanged.

Distributed keyed reset awaits `DistributedRateLimitStore.reset(key:)` and propagates
the original store error. Global reset-all can reset its one known global key.
Non-global reset-all requires `ResettableDistributedRateLimitStore.resetAll(keyPrefix:)`;
otherwise it throws `RateLimitResetError.resetAllUnsupported`. Existing store conformers
remain valid for admission, status, and keyed reset without adopting the new capability.
`InMemoryRateLimitStore` implements the capability.

The prefix identifies one PipelineKit scope in the backing store's budget namespace.
Adapters must apply their own namespace framing consistently to normal keys and reset
prefixes. Reset-all must reach keys written by other limiter instances; clearing only
locally observed identifiers is insufficient. A reset orders against concurrent
admissions according to the backing store's operations and does not prevent future
admissions. Distributed status retains its existing read-error behavior in this batch.

## Outstanding limits and oldest-waiter eviction

A finite `maxOutstanding` now bounds executing plus queued work for every overload
strategy. Increase it explicitly if an application relied on the former suspend
allowance of twice the configured limit or timed-error queueing beyond that limit.

| Strategy | At the outstanding limit |
| --- | --- |
| `.suspend` | Reject with queue-full; wait for a permit only while queue capacity exists. |
| `.error(timeout:)` | Nil or positive timeouts reject with queue-full; nonpositive timeouts retain immediate-only timeout rejection. |
| `.dropNewest` | Reject the incoming operation as dropped. |
| `.dropOldest` | Replace the earliest-enqueued waiter if one exists and the replacement fits queue memory; otherwise reject. |

Eviction never cancels an already executing operation. Oldest eviction uses insertion
order independently of service priority or wall-clock timestamps. Service still selects
higher-priority waiters first, with FIFO order within a priority. A rejected replacement
must leave the existing queue and its permit ownership intact.

`BackPressureMiddleware` and `ConcurrentPipeline` return their owned capacity before
an awaited execution returns or throws. Sequential calls therefore remain usable at
an outstanding limit of one, including after handler failures.

Immediate-only admission timeouts do not enqueue or evict. Existing admission duration
validation, cancellation classification, and nil `PipelineOptions` capacity semantics
remain in effect. The direct semaphore initializer retains its documented derived
default when its outstanding limit is omitted; any resolved finite limit is strict.

The policy regression suites and the ordinary-import Consumer `policy-contract` mode
cover these public contracts. See [validation commands](../../Scripts/validation/README.md).
