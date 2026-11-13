# Performance Guide

This guide focuses on practical ways to keep PipelineKit fast and predictable, using only APIs that ship in the package.

## Quick Wins

### 1) Build Pipelines Once

Construct pipelines up front and reuse them:

```swift
let builder = PipelineBuilder(handler: handler)
await builder.addMiddleware(middleware)
let pipeline = try await builder.build()
```

### 2) Manage Concurrency Explicitly

`StandardPipeline(handler:maxConcurrency:)` acquires a `SimpleSemaphore` permit before each
execution:

```swift
let limited = StandardPipeline(
    handler: handler,
    maxConcurrency: 64
)
```

`StandardPipeline(handler:options:)` applies only `maxConcurrency` from `PipelineOptions`. It
ignores `maxOutstanding`, `maxQueueMemory` and any strategy other than `.suspend`; when
`maxConcurrency` is set it logs a warning for each of those it was given, and when
`maxConcurrency` is `nil` the pipeline has no limit at all. To bound queued work or shed load,
add `BackPressureMiddleware`; see
[Understanding Concurrency Controls](resilience-patterns.md#understanding-concurrency-controls).

### 3) Dispatch per Batch, Not per Element

Every `execute` does work that does not depend on the command's payload: a call into the
pipeline actor, a `CommandContext`, and one call through each middleware. For a stream of small
items, make the command carry a batch, so that work is done once per batch instead of once per
item. The same applies to metrics: `MetricsStorage.record` is an actor call whose cost grows
with the history already retained for that series, so record once per batch.

[`BatchIngestExample`](../../Examples/Sources/BatchIngestExample/main.swift) is a runnable
version: one command per batch of vectors, `BackPressureMiddleware` for the concurrency and
outstanding-work limits, and a driver that pulls the next batch only when one finishes. It
prints no timings. [benchmarks.md](../benchmarks.md) has the published cost of one dispatch
through a pipeline with no middleware (the `dispatch` workload) and of a record as retained
history grows (the `telemetry` workload), and the harness to repeat both on your hardware.

### 4) Keep Context Lightweight

Best practices:
- Store small, value‑type data in `CommandContext`
- Prefer `ContextKey<T>` over dynamic keys
- Avoid large blobs; pass references to external caches instead

### 5) Pool Expensive Resources

`PipelineKitPooling` provides an actor-based object pool.

```swift
import PipelineKitPooling

let configuration = try ObjectPoolConfiguration(
    maxSize: 50,
    highWaterMark: 40,
    lowWaterMark: 10
)

let pool = ObjectPool<DatabaseConnection>(
    configuration: configuration,
    factory: { DatabaseConnection() },
    reset: { conn in conn.prepareForReuse() } // synchronous reset
)

// Automatic resource management
let connection = try await pool.acquire()
// Use connection...
await pool.release(connection)
```

`DatabaseConnection` stands in for your own `Sendable` type.

## Measuring Performance

Use XCTest performance tests or simple timing:

```swift
let start = CFAbsoluteTimeGetCurrent()
for _ in 0..<10_000 {
    _ = try await pipeline.execute(command, context: context)
}
let duration = CFAbsoluteTimeGetCurrent() - start
print("ops/s: \(Int(10_000 / max(duration, 0.0001)))")
```

## Middleware Tips

- Avoid capturing large objects in closures
- Use `ExecutionPriority` to enforce sensible order
- For middleware that returns a result without calling `next()` (e.g., caching), adopt `NextGuardWarningSuppressing`; since 0.6, throw‑based short‑circuits are detected automatically and don't need it

## Troubleshooting

- High latency: inspect middleware work; ensure handlers aren’t blocking
- Memory growth: check for retained closures or long‑lived references
- Low throughput: adjust concurrency; ensure downstreams (DB/HTTP) aren’t saturated

## Summary

Reusing pipelines, setting clear concurrency limits, and keeping context lean go a long way. Measure under realistic load and iterate with minimal, focused changes.
