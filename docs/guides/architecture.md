# PipelineKit Architecture

This document describes PipelineKit’s core building blocks, execution flow, and design principles. It reflects the current APIs and implementation.

## Core Components

### Command

```swift
public protocol Command: Sendable {
    associatedtype Result: Sendable
}
```

- Value types preferred; immutable data is ideal
- Result must be Sendable for concurrency safety

### CommandHandler

```swift
public protocol CommandHandler: Sendable {
    associatedtype CommandType: Command
    func handle(_ command: CommandType, context: CommandContext) async throws -> CommandType.Result
}
```

- One handler per command type
- Receives `CommandContext` for metadata, correlation IDs, transactions
- Async/await for modern concurrency
- Throws for explicit error handling

### CommandContext

```swift
@dynamicMemberLookup
public final class CommandContext: @unchecked Sendable {
    // Typed storage access
    public func set<T: Sendable>(_ key: ContextKey<T>, value: T?)
    public func get<T: Sendable>(_ key: ContextKey<T>) -> T?

    // Built‑in properties (via dynamic member lookup)
    public var requestID: String? { get set }
    public var userID: String? { get set }
    public var correlationID: String? { get set }
}
```

- Thread-safe class with internal locking (not an actor)
- Type‑safe storage via ContextKey<T>
- Built‑in keys accessible via property syntax
- `@dynamicMemberLookup` for ergonomic access

### Middleware

```swift
public protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}
```

- ExecutionPriority (lower executes earlier); ties preserve insertion order (stable)
- Access to both command and context
- NextGuard enforces exactly‑once/concurrency safety for `next` calls

### Pipeline

```swift
public protocol Pipeline: Sendable {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result
}
```

Implementations:
- StandardPipeline<C,H>: type‑safe pipeline for a single command type/handler
- AnyStandardPipeline: type‑erased convenience pipeline
- DynamicPipeline: runtime registry and routing by command type
- PipelineBuilder: fluent builder with stable ordering

## Execution Flow

```
Command → Pipeline → [Middleware…] → Handler → Result
             ↑                          ↓
           Context ←——— Shared state ———┘
```

## Performance & Concurrency

- Stable ordering: middleware sorted by ExecutionPriority; ties preserve insertion order
- Concurrency limits: StandardPipeline can be constructed with maxConcurrency or PipelineOptions
- Back‑pressure: for advanced scenarios, compose resilience middleware (e.g., bulkhead) from PipelineKitResilience
- NextGuard: ensures `next` is called exactly once; use UnsafeMiddleware to opt‑out, and NextGuardWarningSuppressing to suppress debug‑only deinit warnings for intentional short‑circuits

## Caching

Use PipelineKitCache for production caching.

```swift
import PipelineKitCache

let cache = InMemoryCache(maxSize: 1000)
let caching = CachingMiddleware(
    cache: cache,
    keyGenerator: { cmd in "\(type(of: cmd)):\(String(describing: cmd).hashValue)" },
    ttl: 300
)
```

## Errors

Selected PipelineError cases:

```swift
public enum PipelineError: Error, Sendable {
    case validation(field: String?, reason: ValidationReason)
    case authorization(reason: AuthorizationReason)
    case rateLimitExceeded(limit: Int, resetTime: Date?, retryAfter: TimeInterval?)
    case executionFailed(message: String, context: ErrorContext?)
    case middlewareError(middleware: String, message: String, context: ErrorContext?)
    case timeout(duration: TimeInterval, context: ErrorContext?)
    case cancelled(context: String?)
}
```

## Extensibility

- Custom middleware: implement Middleware and choose an appropriate ExecutionPriority
- Context keys: define ContextKey<T>("name") for type‑safe values
- Builder extensions: add fluent helpers that call `.add...` aliases

## Notes

- AnySendable is intentionally not Equatable/Hashable; unwrap with `get(_:)` to compare/hash
- SwiftLog is the internal logging facade; OSLog can be used via a backend on Apple platforms
- Observability: use ObservabilitySystem + EventHub to emit events and record metrics
