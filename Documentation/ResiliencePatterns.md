# PipelineKit Resilience Patterns

This document provides guidance on using PipelineKit's resilience middleware effectively. Understanding when and how to use each pattern is critical for building robust, production-ready command pipelines.

## Pattern Overview

| Pattern | Purpose | When to Use |
|---------|---------|-------------|
| **Rate Limiting** | Enforce request rate limits | External API limits, fair usage policies |
| **Circuit Breaker** | Fail fast for unhealthy services | Downstream health matters |
| **Bulkhead** | Isolate resources per partition | Multi-tenant, per-service isolation |
| **Back-Pressure** | Throttle global throughput | Prevent system overload |
| **Timeout** | Bound execution time | Worst-case latency bounds |
| **Retry** | Handle transient failures | Network issues, temporary errors |

## Recommended Middleware Ordering

When using multiple resilience patterns, **order matters**. Middleware executes in priority order (lower values first):

```
Command → RateLimit → CircuitBreaker → Bulkhead → Timeout → Retry → Handler
```

| Priority | Middleware | Rationale |
|----------|------------|-----------|
| 50 | RateLimitingMiddleware | Reject early before consuming resources |
| 100 | CircuitBreakerMiddleware | Fail fast for unhealthy dependencies |
| 200 | BulkheadMiddleware | Isolate resources per partition |
| 300 | TimeoutMiddleware | Bound maximum execution time |
| 400 | RetryMiddleware | Retry transient failures (innermost) |

### Why This Order?

1. **Rate Limiting First**: Prevents overload at the source. If you're rate-limited, there's no point in executing further.

2. **Circuit Breaker Second**: If a downstream service is unhealthy, fail fast. Don't waste resources or queue capacity.

3. **Bulkhead Third**: Isolate concurrent operations by partition (tenant, service, etc.) to prevent one partition from starving others.

4. **Timeout Fourth**: Bound the worst-case execution time. This applies to the retry loop as a whole.

5. **Retry Last (Innermost)**: Retry transient failures from the handler. The retry loop is bounded by the timeout.

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

try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 30.0))
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
        resetTimeout: 30.0,
        halfOpenMaxAttempts: 3
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 10.0))

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

For workloads shared across tenants:

```swift
try await pipeline.addMiddleware(BulkheadMiddleware(
    configuration: .init(
        maxConcurrency: 10,
        isolationMode: .tagged { command in
            (command as? TenantIdentifiable)?.tenantId ?? "default"
        }
    )
))
```

**Key considerations:**
- Isolate resources per tenant to prevent starvation
- Set per-tenant concurrency limits
- Consider per-tenant rate limiting for fair usage

### External API Integration

For calling third-party APIs with rate limits:

```swift
try await pipeline.addMiddleware(RateLimitingMiddleware(
    configuration: .init(
        limit: 100,
        window: .minute,
        strategy: .slidingWindow
    )
))

try await pipeline.addMiddleware(CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,
        resetTimeout: 60.0
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 15.0))

try await pipeline.addMiddleware(RetryMiddleware.forNetworkRequests())
```

**Key considerations:**
- Rate limit to respect API quotas
- Circuit breaker to handle API outages gracefully
- Retry transient failures with backoff

## Common Configurations

### High-Throughput Pipeline

Optimized for maximum throughput with back-pressure control:

```swift
let pipeline = StandardPipeline(
    handler: handler,
    options: .highThroughput()  // maxConcurrency: 50, maxOutstanding: 200
)

try await pipeline.addMiddleware(BulkheadMiddleware.highThroughput())
try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 5.0))
```

### Low-Latency Pipeline

Optimized for fast responses with strict limits:

```swift
let pipeline = StandardPipeline(
    handler: handler,
    options: .lowLatency()  // maxConcurrency: 5, maxOutstanding: 10
)

try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 1.0))
```

### Resilient External Service Call

Full resilience stack for unreliable external services:

```swift
try await pipeline.addMiddleware(RateLimitingMiddleware(limit: 100, per: .minute))

try await pipeline.addMiddleware(CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,
        resetTimeout: 30.0,
        triggeredByErrors: [.timeout, .networkError, .serverError]
    )
))

try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 10.0))

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

try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 5.0))

try await pipeline.addMiddleware(RetryMiddleware.forDatabaseOperations())
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

- Uses `BackPressureSemaphore` with advanced features
- Supports multiple back-pressure strategies (suspend, drop, error)
- Queue limits and memory tracking
- Priority-based queuing

```swift
try await pipeline.addMiddleware(BackPressureMiddleware(
    maxConcurrency: 10,
    maxOutstanding: 50,
    strategy: .suspend
))
```

### `BulkheadMiddleware`

- Isolates resources by partition (tag)
- Prevents one partition from consuming all resources
- Essential for multi-tenant systems

```swift
try await pipeline.addMiddleware(BulkheadMiddleware(
    configuration: .init(
        maxConcurrency: 5,
        isolationMode: .tagged { command in command.partitionKey }
    )
))
```

### When to Use Which

| Scenario | Recommended Control |
|----------|---------------------|
| Simple concurrency limit | `StandardPipeline(maxConcurrency:)` |
| Advanced queue management | `BackPressureMiddleware` |
| Multi-tenant isolation | `BulkheadMiddleware` |
| Multiple isolation levels | Combine `StandardPipeline` + `BulkheadMiddleware` |

## Anti-Patterns to Avoid

### 1. Retry Without Timeout

```swift
// BAD: Retries can run forever
try await pipeline.addMiddleware(RetryMiddleware(maxAttempts: 10))

// GOOD: Bound total retry time
try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 30.0))
try await pipeline.addMiddleware(RetryMiddleware(
    configuration: .init(
        maxAttempts: 5,
        maxRetryTime: 25.0  // Also limit total retry time
    )
))
```

### 2. Retry Non-Idempotent Operations

```swift
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

```swift
// BAD: Circuit breaker on in-memory operations
try await pipeline.addMiddleware(CircuitBreakerMiddleware(...))
try await pipeline.execute(ValidateInputCommand(...))  // Pure CPU work

// GOOD: Only use circuit breaker for external dependencies
// Skip circuit breaker for local/in-memory operations
```

### 4. Overly Aggressive Timeouts

```swift
// BAD: 100ms timeout on database operation
try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 0.1))

// GOOD: Set timeouts based on measured P99 latency + margin
try await pipeline.addMiddleware(TimeoutMiddleware(timeout: 5.0))
```

## Monitoring and Observability

All resilience middleware emit events through PipelineKit's observability system. Subscribe to these events for monitoring:

```swift
let eventHub = EventHub.shared

// Monitor circuit breaker state changes
await eventHub.subscribe(CircuitBreakerSubscriber { event in
    switch event.state {
    case .open:
        metrics.recordCircuitOpen(service: event.serviceName)
    case .halfOpen:
        metrics.recordCircuitHalfOpen(service: event.serviceName)
    case .closed:
        metrics.recordCircuitClosed(service: event.serviceName)
    }
})

// Monitor retry attempts
await eventHub.subscribe(name: .middlewareRetry) { event in
    metrics.recordRetryAttempt(
        command: event.properties["commandType"] as? String,
        attempt: event.properties["attempt"] as? Int
    )
}
```

## Performance Considerations

### Middleware Overhead

Each middleware adds a small amount of latency. For ultra-low-latency paths:

1. **Minimize middleware count**: Only add what's necessary
2. **Use conditional middleware**: Skip middleware that doesn't apply

```swift
// Middleware only activates for specific commands
struct NetworkCommand: Command, RequiresResilience {}

try await pipeline.addMiddleware(
    ConditionalRetryMiddleware()  // Only runs for RequiresResilience commands
)
```

### Semaphore Choice

- `SimpleSemaphore`: ~0.1μs overhead per acquire/release
- `BackPressureSemaphore`: ~1-5μs overhead with queue management

For most applications, this overhead is negligible. Only optimize if profiling shows it's a bottleneck.
