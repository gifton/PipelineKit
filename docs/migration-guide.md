# Migration Guide

This guide helps you migrate to newer versions of PipelineKit.

## Migrating to 0.1.0

If you're adopting PipelineKit for the first time, see our [Getting Started](getting-started.md) guide.

### From Pre-Release Versions

If you were using pre-release versions of PipelineKit, here are the key changes:

#### CommandContext API Changes

The most significant change is the removal of async/await from CommandContext operations.

**Before:**
```swift
// Pre-release API (actor-based)
let value = await context.get(MyKey.self)
await context.set(newValue, for: MyKey.self)
await context.remove(MyKey.self)
```

**After:**
```swift
// 0.1.0 API (thread-safe class)
let value = context.get(MyKey.self)
context.set(newValue, for: MyKey.self)
context.remove(MyKey.self)
```

**Migration Steps:**
1. Remove all `await` keywords from context operations
2. Update any error handling that expected async errors
3. Test thoroughly as timing behavior may change

#### Middleware Signature Changes

**Before:**
```swift
func handle<T: Command>(
    _ command: T,
    context: CommandContext,
    next: @escaping (T, CommandContext) async throws -> T.Result
) async throws -> T.Result
```

**After:**
```swift
func execute<T: Command>(
    _ command: T,
    context: CommandContext,
    next: @Sendable (T, CommandContext) async throws -> T.Result
) async throws -> T.Result
```

**Changes:**
- Method renamed from `handle` to `execute`
- `next` closure now requires `@Sendable`

#### ExecutionPriority Changes

**Before:**
```swift
ExecutionPriority.monitoring  // Removed
ExecutionPriority.logging     // Removed
```

**After:**
```swift
ExecutionPriority.postProcessing  // Use for monitoring/logging
ExecutionPriority.custom(750)     // Or use custom priority
```

### Performance Improvements

Take advantage of new performance features:

#### 1. Pre-Compiled Pipelines

**Before:**
```swift
let pipeline = try await PipelineBuilder(handler: handler)
    .with(middleware)
    .build()
```

**After:**
```swift
let pipeline = try await PipelineBuilder(handler: handler)
    .with(middleware)
    .buildOptimized()  // 30% faster execution
```

#### 2. Context Pooling

**Before:**
```swift
let context = CommandContext(metadata: metadata)
let result = try await pipeline.execute(command, context: context)
```

**After:**
```swift
// Automatic pooling
let result = try await pipeline.execute(command, metadata: metadata)
```

#### 3. Parallel Middleware

**Before:**
```swift
pipeline
    .with(LoggingMiddleware())
    .with(MetricsMiddleware())
    .with(AuditMiddleware())
```

**After:**
```swift
let parallel = ParallelMiddlewareWrapper(
    wrapping: [LoggingMiddleware(), MetricsMiddleware(), AuditMiddleware()],
    strategy: .sideEffectsOnly
)
pipeline.with(parallel)  // 2-3x faster
```

#### 4. Cached Middleware

For expensive middleware operations:

```swift
let cached = ExpensiveMiddleware().cached(ttl: 300)
pipeline.with(cached)
```

### Removed APIs

The following APIs have been removed:

- `Context` type alias (use `CommandContext`)
- `OptimizedCommandContext` (functionality merged into `CommandContext`)
- `ContextAwarePipeline` (all pipelines are now context-aware)
- `ExecutionPriority.monitoring` (use `.postProcessing`)

### New Features

Take advantage of new capabilities:

#### Middleware Wrappers
- `TimeoutMiddlewareWrapper`: Add timeouts to any middleware
- `CachedMiddleware`: Cache expensive operations
- `ConditionalCachedMiddleware`: Cache based on conditions

#### Builder Extensions
```swift
.with(middleware.cached())
.with(middleware.withTimeout(5.0))
.with(middleware.cachedWhen { cmd, ctx in shouldCache(cmd) })
```

#### Performance Monitoring
```swift
let stats = pipeline.getOptimizationStats()
print("Optimizations applied: \(stats.optimizationsApplied)")
print("Estimated improvement: \(stats.estimatedImprovement)%")
```

### Testing Changes

Update your tests to work with the new synchronous context API:

**Before:**
```swift
func testContextOperations() async {
    let context = CommandContext(metadata: TestMetadata())
    await context.set("value", for: TestKey.self)
    let value = await context.get(TestKey.self)
    XCTAssertEqual(value, "value")
}
```

**After:**
```swift
func testContextOperations() {
    let context = CommandContext(metadata: TestMetadata())
    context.set("value", for: TestKey.self)
    let value = context.get(TestKey.self)
    XCTAssertEqual(value, "value")
}
```

### Common Issues

#### Issue: "Cannot convert value of type '() async -> Void' to expected type '() -> Void'"

**Solution:** Remove `async` from context operation closures:
```swift
// Before
Task {
    await context.set(value, for: Key.self)
}

// After
context.set(value, for: Key.self)  // No Task needed
```

#### Issue: "Type 'MyMiddleware' does not conform to protocol 'Middleware'"

**Solution:** Update method signature:
```swift
// Change 'handle' to 'execute'
// Add @Sendable to next parameter
func execute<T: Command>(
    _ command: T,
    context: CommandContext,
    next: @Sendable (T, CommandContext) async throws -> T.Result
) async throws -> T.Result
```

#### Issue: Performance regression after migration

**Solution:** Enable optimizations:
```swift
// Use buildOptimized()
let pipeline = try await builder.buildOptimized()

// Enable context pooling
ContextPoolConfiguration.usePoolingByDefault = true

// Use parallel middleware where appropriate
```

### Verification Checklist

After migration, verify:

- [ ] All `await` removed from context operations
- [ ] Middleware updated to use `execute` method
- [ ] `@Sendable` added to next closures
- [ ] ExecutionPriority values updated
- [ ] Tests updated and passing
- [ ] Performance optimizations enabled
- [ ] No deprecation warnings

### Getting Help

If you encounter issues during migration:

1. Check the [API Reference](api-reference.md)
2. Review [Examples](examples/basic-usage.md)
3. Search [existing issues](https://github.com/yourusername/PipelineKit/issues)
4. Ask in [Discussions](https://github.com/yourusername/PipelineKit/discussions)
5. File a [bug report](https://github.com/yourusername/PipelineKit/issues/new)

### Future Versions

We follow semantic versioning:
- **Patch versions** (0.1.x): Bug fixes, no API changes
- **Minor versions** (0.x.0): New features, backwards compatible
- **Major versions** (x.0.0): Breaking changes with migration guide

Subscribe to releases to stay informed about updates.