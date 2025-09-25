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

Use `StandardPipeline` initializers to control concurrency and back‑pressure:

```swift
// Limit concurrent executions
let limited = StandardPipeline(
    handler: handler,
    maxConcurrency: 64
)

// Or use options for future back‑pressure integration
let withOptions = StandardPipeline(
    handler: handler,
    options: PipelineOptions(
        maxConcurrency: 64,
        maxOutstanding: 512,
        backPressureStrategy: .suspend
    )
)
```

### 3) Keep Context Lightweight

Best practices:
- Store small, value‑type data in `CommandContext`
- Prefer `ContextKey<T>` over dynamic keys
- Avoid large blobs; pass references to external caches instead

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
- For short‑circuiting middleware (e.g., caching), adopt `NextGuardWarningSuppressing`

## Troubleshooting

- High latency: inspect middleware work; ensure handlers aren’t blocking
- Memory growth: check for retained closures or long‑lived references
- Low throughput: adjust concurrency; ensure downstreams (DB/HTTP) aren’t saturated

## Summary

Reusing pipelines, setting clear concurrency limits, and keeping context lean go a long way. Measure under realistic load and iterate with minimal, focused changes.
