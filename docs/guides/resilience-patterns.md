# PipelineKit Resilience Patterns

For 0.6.0, follow the [upgrade guide](../migrations/0.5-to-0.6.md#resilience). Ordinary and partitioned queue timeouts accept nil (unbounded), finite nonpositive values (no wait), or finite positive values at most 86,400 seconds; nonfinite and larger positive values are invalid. Nil does not preserve a longer finite deadline. Capacity remains owned until downstream work settles. Distributed scope-key changes require coordinated counter migration; typed timeout classification ignores non-timeout PipelineError payload text.


This document provides guidance on using PipelineKit's resilience middleware effectively. Understanding when and how to use each pattern is critical for building robust, production-ready command pipelines.

## Pattern Overview

| Pattern | Purpose | When to Use |
|---------|---------|-------------|
| **Rate Limiting** | Enforce request rate limits | External API limits, fair usage policies |
| **Circuit Breaker** | Fail fast for unhealthy services | Downstream health matters |
| **Bulkhead** | Bound concurrency with a shared limit (`BulkheadMiddleware`); isolate per partition (`PartitionedBulkheadMiddleware`) | Multi-tenant, per-service isolation (via `PartitionedBulkheadMiddleware`) |
| **Back-Pressure** | Throttle global throughput | Prevent system overload |
| **Timeout** | Bound execution time | Worst-case latency bounds |
| **Retry** | Handle transient failures | Network issues, temporary errors |

## Recommended Middleware Ordering

When using multiple resilience patterns, **order matters**. Middleware executes
in `ExecutionPriority` order (lower values first), and equal priorities
preserve insertion order (stable ordering):

```
Command → RateLimit → CircuitBreaker → Bulkhead → Timeout → Retry → Handler
```

`RateLimitingMiddleware` genuinely precedes the rest by priority — it's
`.authentication` (100). But `CircuitBreakerMiddleware`, `BulkheadMiddleware`,
`TimeoutMiddleware`, and `RetryMiddleware` all share the *same* priority,
`.resilience` (250); there is no numeric distinction between them. Their
relative order above is achieved by **insertion order** — call
`addMiddleware` in the sequence you want them to run, not by picking
different priority values.

| Middleware | `ExecutionPriority` | Rationale |
|----------|------------|-----------|
| RateLimitingMiddleware | `.authentication` (100) | Reject early before consuming resources |
| CircuitBreakerMiddleware | `.resilience` (250) | Fail fast for unhealthy dependencies |
| BulkheadMiddleware | `.resilience` (250) | Bound concurrent executions with a shared limit (see `PartitionedBulkheadMiddleware` for per-partition isolation) |
| TimeoutMiddleware | `.resilience` (250) | Bound maximum execution time |
| RetryMiddleware | `.resilience` (250) | Retry transient failures (innermost) |

### Why This Order?

1. **Rate Limiting First**: Prevents overload at the source. If you're rate-limited, there's no point in executing further. This is enforced by priority — `.authentication` runs before `.resilience` regardless of insertion order.

2. **Circuit Breaker Second**: If a downstream service is unhealthy, fail fast. Don't waste resources or queue capacity. Add this middleware before Bulkhead/Timeout/Retry so it runs first among the `.resilience`-priority group.

3. **Bulkhead Third**: Bound concurrent executions (or, with `PartitionedBulkheadMiddleware`, isolate them by partition — tenant, service, etc.) to prevent one workload from starving the rest.

4. **Timeout Fourth**: Request cancellation of the retry loop after its budget. Cancellation-insensitive work can delay settlement; this is not a hard deadline.

5. **Retry Last (Innermost)**: Retry transient failures from the handler. The timeout requests cancellation of the retry loop; completion still requires downstream settlement. Since all four share `.resilience` priority, adding them to `addMiddleware` in this exact sequence is what actually produces this order.

## Choosing the Right Pattern

### CPU-Bound Operations (ML, Image Processing)

For operations that consume CPU cycles heavily:

```swift
let pipeline = StandardPipeline(handler: handler, maxConcurrency: 4)

try await pipeline.addMiddleware(BulkheadMiddleware(
    configuration: .init(
        maxConcurrency: ProcessInfo.processInfo.activeProcessorCount,
        maxQueueSize: 50
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 30.0))
```

**Key considerations:**
- Limit concurrency to CPU core count (or slightly higher)
- Use bulkheads to prevent queue buildup
- Set generous timeouts for long-running operations
- Avoid retry for CPU-bound work (retry won't help)

### I/O-Bound Operations (Network, Database)

For operations waiting on external systems:

```swift
try await pipeline.addMiddleware(CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,
        recoveryTimeout: 30.0,
        halfOpenSuccessThreshold: 3
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 10.0))

try await pipeline.addMiddleware(RetryMiddleware(
    configuration: .init(
        maxAttempts: 3,
        strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0),
        retryableErrors: [.timeout, .networkError, .temporaryFailure]
    )
))
```

**Key considerations:**
- Use circuit breaker to detect downstream failures
- Set timeouts appropriate for your SLAs
- Retry only transient/retryable errors
- Use exponential backoff with jitter to prevent thundering herd

### Multi-Tenant Workloads

For workloads shared across tenants, use `PartitionedBulkheadMiddleware` with
`allowBorrowing: false`. Each declared partition owns its capacity, and the
`partitionExtractor` receives both the command and the `CommandContext`.
The old `.tagged` mode shared one semaphore; it was deprecated in 0.5.4 and
is removed in 0.6.0. Move any custom tag metadata into
your own middleware and configure partitions for capacity isolation.

`PartitionedBulkheadMiddleware` requires every partition to be declared up
front in `partitions`, so this fits a small, known set of tenants (or tenant
tiers) — it is **not** suited to unbounded or dynamically-discovered tenant
counts, since any tenant ID that doesn't match a declared partition silently
falls back to `defaultPartition` rather than getting its own isolated
capacity. Tag the command itself with its tenant so the extractor has a
real, meaningful key to route on:

```swift
protocol TenantScoped {
    var tenantID: String { get }
}

try await pipeline.addMiddleware(PartitionedBulkheadMiddleware(
    configuration: .init(
        partitions: [
            "tenant-a": .init(capacity: 10),
            "tenant-b": .init(capacity: 10)
        ],
        partitionExtractor: { command, _ in
            (command as? TenantScoped)?.tenantID ?? "tenant-a"
        },
        defaultPartition: "tenant-a"
    )
))
```

**Key considerations:**
- Partitions are static and must be declared up front — enumerate your known
  tenants (or tenant tiers) rather than deriving keys from unbounded request data
- Isolate resources per tenant to prevent starvation
- Set per-tenant concurrency limits (`PartitionConfig.capacity`)
- Consider per-tenant rate limiting for fair usage

### External API Integration

For calling third-party APIs with rate limits:

```swift
try await pipeline.addMiddleware(RateLimitingMiddleware(
    limiter: RateLimiter(strategy: .slidingWindow(windowSize: 60, maxRequests: 100)),
    identifierExtractor: { _, context in
        context.commandMetadata.userID ?? "anonymous"
    }
))

try await pipeline.addMiddleware(CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,
        recoveryTimeout: 60.0
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 15.0))

try await pipeline.addMiddleware(RetryMiddleware.forNetworkRequests())
```

**Key considerations:**
- Rate limit to respect API quotas
- Circuit breaker to handle API outages gracefully
- Retry transient failures with backoff

## Common Configurations

`StandardPipeline(handler:options:)` applies only `maxConcurrency` from `PipelineOptions`. It
ignores `maxOutstanding`, `maxQueueMemory` and any strategy other than `.suspend`, logging a
warning for each of those it was given, so in the first two configurations below the pipeline
itself contributes a concurrency limit and nothing else.

### High-Throughput Pipeline

A concurrency limit on the pipeline, with queueing bounded by the bulkhead:

```swift
let pipeline = StandardPipeline(
    handler: handler,
    options: .highThroughput()  // maxConcurrency: 50, maxOutstanding: 200
)

try await pipeline.addMiddleware(BulkheadMiddleware(maxConcurrency: 50, maxQueueSize: 200))
try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 5.0))
```

### Low-Latency Pipeline

Optimized for fast responses with strict limits:

```swift
let pipeline = StandardPipeline(
    handler: handler,
    options: .lowLatency()  // maxConcurrency: 5, maxOutstanding: 10
)

try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 1.0))
```

### Resilient External Service Call

Full resilience stack for unreliable external services:

```swift
try await pipeline.addMiddleware(RateLimitingMiddleware(
    limiter: RateLimiter(strategy: .slidingWindow(windowSize: 60, maxRequests: 100)),
    identifierExtractor: { _, context in
        context.commandMetadata.userID ?? "anonymous"
    }
))

try await pipeline.addMiddleware(CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,
        recoveryTimeout: 30.0,
        triggeredByErrors: [.timeout, .networkError, .serverError]
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 10.0))

try await pipeline.addMiddleware(RetryMiddleware(
    configuration: .init(
        maxAttempts: 3,
        strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0)
    )
))
```

### Database Operations

Appropriate for database calls with connection limits:

```swift
let pipeline = StandardPipeline(handler: handler, maxConcurrency: 20)

try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 5.0))

try await pipeline.addMiddleware(RetryMiddleware.forDatabaseOperations())
```

### Per-Command Timeouts

```swift
let timeout = TimeoutMiddleware(defaultTimeout: 5.0)

// Or with per-command timeouts
let timeoutWithOverrides = TimeoutMiddleware(
    configuration: TimeoutMiddleware.Configuration(
        defaultTimeout: 5.0,
        commandTimeouts: ["SlowCommand": 30.0]
    )
)
```

## Understanding Concurrency Controls

PipelineKit provides multiple overlapping concurrency controls. Here's how they differ:

### `StandardPipeline(maxConcurrency:)`

- Uses `SimpleSemaphore` internally
- Limits concurrent executions at the pipeline level
- Simple and efficient for most use cases
- No queue management or back-pressure strategies

```swift
let pipeline = StandardPipeline(handler: handler, maxConcurrency: 10)
```

### `BackPressureMiddleware`

- Uses `BackPressureSemaphore`
- Runs at most `maxConcurrency` executions and queues the rest, up to `maxOutstanding`
  executing and queued in total (default: five times `maxConcurrency`)
- At that bound, `.suspend` and `.error` reject the new command with
  `PipelineError.backPressure(reason: .queueFull)`; `.dropOldest` evicts the oldest queued
  command with `.commandDropped`, or rejects the new one with `.queueFull` when nothing is
  queued; `.dropNewest` rejects the new command with `.commandDropped`
- `maxQueueMemory` bounds the estimated size of queued commands
- Every command queues at the same priority; priorities are available by using
  `BackPressureSemaphore` directly

[`BatchIngestExample`](../../Examples/Sources/BatchIngestExample/main.swift) runs both cases:
a caller that stays within `maxOutstanding`, and one that exceeds it and is rejected.

```swift
try await pipeline.addMiddleware(BackPressureMiddleware(
    maxConcurrency: 10,
    maxOutstanding: 50,
    strategy: .suspend
))
```

### `BackPressureSemaphore` (direct use)

The semaphore behind `BackPressureMiddleware` can be used on its own.

```swift
let semaphore = BackPressureSemaphore(
    maxConcurrency: 100,
    maxOutstanding: 1000,
    maxQueueMemory: 10_485_760 // 10MB
)

let token = try await semaphore.acquire(
    priority: .high,
    estimatedSize: 1024
)
// Token auto-releases when deallocated
```

### `BulkheadMiddleware`

- Limits concurrent executions with a single shared semaphore (`maxConcurrency`)
- `.semaphore` and `.taskGroup` share the configured concurrency limit.
- For true per-partition isolation (e.g. multi-tenant systems), use
  `PartitionedBulkheadMiddleware` instead (see "Multi-Tenant Workloads" above)

```swift
let pipeline = DynamicPipeline()

try await pipeline.addMiddleware(BulkheadMiddleware(
    configuration: .init(
        maxConcurrency: 5,
        isolationMode: .semaphore
    )
))
```

### When to Use Which

| Scenario | Recommended Control |
|----------|---------------------|
| Simple concurrency limit | `StandardPipeline(maxConcurrency:)` |
| Advanced queue management | `BackPressureMiddleware` |
| Multi-tenant isolation | `PartitionedBulkheadMiddleware` |
| Multiple isolation levels | Combine `StandardPipeline` + `BulkheadMiddleware` |

## Anti-Patterns to Avoid

### 1. Retry Without Timeout

```swift
let pipeline = DynamicPipeline()
// Limit retry admission and request cooperative cancellation for slow attempts.
try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 30.0))
try await pipeline.addMiddleware(RetryMiddleware(
    configuration: .init(
        maxAttempts: 5,
        maxRetryTime: 25.0  // Budget for attempt admission and backoff; admitted work settles
    )
))
```

### 2. Retry Non-Idempotent Operations

`ProcessPaymentCommand(...)` below is illustrative pseudocode (elided
arguments), not literal compilable Swift.

```text
// BAD: Payment might be processed multiple times
try await pipeline.addMiddleware(RetryMiddleware.aggressive())
try await pipeline.execute(ProcessPaymentCommand(...))

// GOOD: Only retry after ensuring idempotency
try await pipeline.addMiddleware(RetryMiddleware(
    configuration: .init(
        maxAttempts: 3,
        errorEvaluator: { error in
            // Only retry if we know payment wasn't processed
            (error as? PaymentError)?.isRetryable == true
        }
    )
))
```

### 3. Circuit Breaker on Local Operations

`CircuitBreakerMiddleware(...)` and `ValidateInputCommand(...)` below are
illustrative pseudocode (elided arguments), not literal compilable Swift.

```text
// BAD: Circuit breaker on in-memory operations
try await pipeline.addMiddleware(CircuitBreakerMiddleware(...))
try await pipeline.execute(ValidateInputCommand(...))  // Pure CPU work

// GOOD: Only use circuit breaker for external dependencies
// Skip circuit breaker for local/in-memory operations
```

### 4. Overly Aggressive Timeouts

```swift
// BAD: 100ms timeout on database operation
try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 0.1))

// GOOD: Set timeouts based on measured P99 latency + margin
try await pipeline.addMiddleware(TimeoutMiddleware(defaultTimeout: 5.0))
```

## Monitoring and Observability

All resilience middleware emit events through PipelineKit's observability system. Subscribe by
implementing `EventSubscriber` (a class-bound protocol) and registering it with an `EventHub`.
The example below assumes a `metrics` service of your own (StatsD client, in-memory counters,
etc.) that exposes the `record*` methods called from `process(_:)`:

```swift
final class ResilienceEventLogger: EventSubscriber {
    func process(_ event: PipelineEvent) async {
        switch event.name {
        case PipelineEvent.Name.circuitOpened:
            metrics.recordCircuitOpen(service: event.properties["service"]?.get(String.self))
        case PipelineEvent.Name.circuitHalfOpen:
            metrics.recordCircuitHalfOpen(service: event.properties["service"]?.get(String.self))
        case PipelineEvent.Name.circuitClosed:
            metrics.recordCircuitClosed(service: event.properties["service"]?.get(String.self))
        case PipelineEvent.Name.middlewareRetry:
            metrics.recordRetryAttempt(
                command: event.properties["commandType"]?.get(String.self),
                attempt: event.properties["attempt"]?.get(Int.self)
            )
        default:
            break
        }
    }
}

let eventHub = EventHub()
await eventHub.subscribe(ResilienceEventLogger())
```

## Performance Considerations

### Middleware Overhead

Each middleware adds a small amount of latency. For ultra-low-latency paths:

1. **Minimize middleware count**: Only add what's necessary
2. **Use conditional middleware**: Skip middleware that doesn't apply — wrap a
   resilience middleware in a generic `ConditionalMiddleware<M: Middleware>`
   that only forwards to it when a predicate matches; see
   [Advanced Patterns](../tutorials/advanced-patterns.md#conditional-middleware-execution)
   for the full pattern.
