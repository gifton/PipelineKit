# PipelineKit Known Limitations

This document outlines known limitations and workarounds in the current PipelineKit implementation.

## Completed Middleware Implementations ✅

All previously missing middleware have been successfully implemented:

### Phase 2 - Core Middleware (Completed)

1. **CachingMiddleware** ✅
   - Location: `/Sources/PipelineKit/Middleware/Caching/`
   - Features: LRU cache, TTL support, type-safe encoding/decoding
   - Registered in MiddlewareRegistry as "caching"

2. **MetricsMiddleware** ✅
   - Location: `/Sources/PipelineKit/Middleware/Metrics/`
   - Features: Advanced metrics with tags, namespaces, multiple metric types
   - Registered in MiddlewareRegistry as "metrics"

3. **DeduplicationMiddleware** ✅
   - Location: `/Sources/PipelineKit/Middleware/Deduplication/`
   - Features: SHA256 fingerprinting, multiple strategies, time windows
   - Registered in MiddlewareRegistry as "deduplication"

### Phase 3 - Advanced Features (Completed)

4. **TracingMiddleware** ✅
   - Location: `/Sources/PipelineKit/Middleware/Tracing/`
   - Features: Distributed tracing, span management, context propagation
   - Registered in MiddlewareRegistry as "tracing"

5. **IdempotencyMiddleware** ✅
   - Location: `/Sources/PipelineKit/Middleware/Idempotency/`
   - Features: Exactly-once semantics, in-progress tracking, concurrent handling
   - Registered in MiddlewareRegistry as "idempotency"

6. **TimeoutMiddleware** ✅
   - Location: `/Sources/PipelineKit/Middleware/Timeout/`
   - Features: Structured concurrency timeouts, command-specific durations
   - Registered in MiddlewareRegistry as "timeout"
   - DSL integration updated to use proper timeout wrapping

## Swift Language Limitations

### 1. Generic Pipeline Middleware Addition
- **Issue**: Cannot add middleware to protocol type `any Pipeline`
- **Location**: `EventProcessingPipelineTemplate`
- **Impact**: Some templates cannot dynamically add middleware
- **Workaround**: Add middleware after concrete pipeline creation

### 2. Parallel Middleware Result Aggregation
- **Issue**: Complex result aggregation in parallel execution
- **Location**: `ParallelMiddlewareWrapper`
- **Impact**: Simplified parallel execution without result aggregation
- **Future**: Implement proper aggregation strategies

### 3. Type-Safe Result Caching
- **Issue**: Type erasure challenges with generic result types
- **Location**: `CachingMiddleware`, `IdempotencyMiddleware`
- **Workaround**: Runtime type checking with fallback behavior

## Template Safeguards

All templates use the `MiddlewareRegistry` to safely handle middleware:
- Runtime warnings are displayed when middleware is not registered
- Templates continue execution without crashing
- Clear instructions are provided for registering custom middleware

## Custom Middleware Registration

To override default middleware implementations:

```swift
// At application startup
await MiddlewareRegistry.shared.register("caching") {
    CachingMiddleware(
        cache: RedisCache(), // Your custom cache backend
        ttl: 600, // 10 minutes
        keyGenerator: { command in
            // Custom key generation logic
        }
    )
}

await MiddlewareRegistry.shared.register("tracing") {
    TracingMiddleware(
        tracer: JaegerTracer(serviceName: "my-service"),
        includeCommandData: true
    )
}
```

## Performance Considerations

1. **In-Memory Stores**: Default implementations use in-memory storage
   - Suitable for development and testing
   - Production systems should use persistent backends

2. **Concurrent Access**: All middleware are thread-safe
   - Uses actors for state management
   - `@unchecked Sendable` for types with internal synchronization

3. **Resource Limits**: Default configurations include:
   - Cache sizes: 1000 entries (configurable)
   - Deduplication windows: 5 minutes
   - Idempotency TTL: 1 hour
   - Timeout defaults: 30 seconds

## Phase 4 - Polish & Optimization (Completed) ✅

### Language Workarounds Resolved
1. **TimeoutMiddleware** ✅
   - Removed old implementation with TODO
   - Using new implementation with proper structured concurrency

2. **Parallel Middleware Execution** ✅
   - Implemented proper parallel execution pattern
   - Added configurable execution policies (fail-fast vs best-effort)
   - Thread-safe error collection and reporting
   - Context forking for isolation

3. **Code Organization** ✅
   - Moved mock implementations to `PipelineKitTestSupport` module
   - Created proper protocols for `CommandEncryptor` and `CommandDecryptor`
   - Cleaned up all placeholder implementations

4. **Template Improvements** ✅
   - Implemented `EncryptionMiddleware` with full functionality
   - Updated all templates to use middleware registry
   - Removed all TODO comments from templates

### Testing Support

The `PipelineKitTestSupport` module now provides:
- `MockEncryptor` and `MockDecryptor` for testing encryption
- `MockCommandProcessor` for testing command transformation
- `MockBatchProcessor` for testing batch operations

## Future Improvements

### Production Enhancements
1. **Storage Backends**
   - Redis adapter for distributed caching/deduplication
   - DynamoDB adapter for idempotency storage
   - PostgreSQL adapter for audit trails
   - S3 adapter for large command archival

2. **Performance Optimizations**
   - Connection pooling for storage backends
   - Batch operations for high-throughput
   - Zero-copy command serialization
   - SIMD optimizations for fingerprinting

3. **Enhanced DSL Operators**
   - Branching operators for conditional paths
   - Merge operators for result aggregation
   - Transform operators for command mapping
   - Circuit breaker operators

4. **Monitoring & Observability**
   - OpenTelemetry integration
   - Prometheus metrics exporter
   - Distributed tracing propagation
   - Performance profiling tools

5. **Additional Middleware Patterns**
   - Bulkhead isolation
   - Adaptive timeout based on load
   - Request coalescing
   - Priority queuing
   - Compensation/Saga support