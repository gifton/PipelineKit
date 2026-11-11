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
    // Typed storage access via subscript
    public subscript<T: Sendable>(_ key: ContextKey<T>) -> T? { get set }

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

```swift
let context = CommandContext()

// String-keyed metadata and metrics
context.setMetadata("client-version", value: "2.0.0")
let clientVersion = context.metadata["client-version"]
```

Built-in keys (`requestID`, `userID`, `correlationID`, `startTime`, and more) are defined on the `ContextKeys` namespace and surfaced as properties on the context; `metadata` and `metrics` are string-keyed dictionaries with both property-style and method-style access.

Event emission is provided via `PipelineKitObservability` (see that module). Core exposes the `EventEmitter` type and forwards to the configured emitter when set.

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
  - `register(_:handler:)` – replace‑by‑default (non‑throwing)
  - `registerOnce(_:handler:)` – throws if a handler already exists
  - `replace(_:with:)` – returns whether a previous handler was replaced
  - `unregister(_:)` – returns whether a handler was removed
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
- NextGuard: ensures `next` is called exactly once; use UnsafeMiddleware to opt‑out. NextGuardWarningSuppressing suppresses debug‑only deinit warnings only for middleware that returns a result without calling `next()` on a normal path (e.g., cache hits) — since 0.6, throw‑based short‑circuits are detected automatically and don't need it

## Caching

Use PipelineKitCache for production caching.

```swift
import PipelineKitCache

struct ProfileQuery: Command {
    typealias Result = String
    let accountID: String
    let locale: String
}

// AuthenticationMiddleware must establish authUserId before protected caching.
let profileKeys = ClosureCacheKeyGenerator { command, context, _ in
    guard let query = command as? ProfileQuery,
          let principal = context.getMetadata("authUserId") as? String else {
        preconditionFailure("Expected an authenticated profile query")
    }
    return [query.accountID, query.locale, principal, "profile-format-v2"]
        .map { "\($0.utf8.count):\($0)" }.joined()
}

let cache = InMemoryCache(maxSize: 1000)
let caching = CachingMiddleware(
    cache: cache,
    commandType: ProfileQuery.self,
    keyGenerator: profileKeys,
    ttl: 300
)
```

## Observability

`PipelineKitObservability` is a separate module.

- `ObservabilitySystem` – unified events + metrics orchestration
- StatsD exporter (UDP) with batching and sampling
- `EventHub` ↔ `MetricsStorage` integration (events can produce metrics)
- `LoggingEmitter` – logs events via OSLog (Apple) or `print` elsewhere

Note: The default UDP transport uses Apple’s Network framework when available; on non‑Apple platforms you can plug in a different transport.

```swift
import PipelineKitObservability

// Production setup
let observability = await ObservabilitySystem.production(
    statsdHost: "localhost",
    statsdPort: 8125,
    prefix: "myapp"
)

// Direct metrics
await observability.recordGauge(name: "queue.depth", value: 42)
await observability.recordCounter(name: "api.requests", value: 1)
await observability.recordTimer(name: "db.query", duration: 0.050)
```

Pipelines do not emit command lifecycle events on their own. To turn events
into metrics, attach an emitter to the context as shown in
[Evaluating PipelineKit, step 5](enterprise-evaluation.md#5-observability-hookup-5-minutes).

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

## Usage guidelines

Each pair below contrasts a good and bad version of the same pattern; several
reuse a type name across both halves or elide bodies with `...`, so the pair
is illustrative pseudocode rather than a single compilable unit.

### Do

#### DO: Keep Commands Simple and Immutable
```text
// ✅ GOOD - Simple data structure
struct UpdateUserCommand: Command {
    typealias Result = User
    let userId: String
    let name: String
    let email: String
}

// ❌ BAD - Contains logic
struct UpdateUserCommand: Command {
    func validate() -> Bool { ... } // Don't put logic in commands!
    var normalizedEmail: String { ... } // Don't compute in commands!
}
```

#### DO: Use Context for Cross-Cutting Data
```swift
// ✅ GOOD - Using context for request metadata
let context = CommandContext()
context.requestID = UUID().uuidString
context.userID = authenticatedUser.id
context.setMetadata("client-version", value: "2.0.0")

// ❌ BAD - Passing auth in every command
struct MyCommand: Command {
    let authToken: String // Don't duplicate auth in every command!
    let userId: String // Use context instead!
}
```

Execution order is set by each middleware's `ExecutionPriority`, not by the order of
`addMiddleware` calls; insertion order only breaks ties. See
[Recommended Middleware Ordering](resilience-patterns.md#recommended-middleware-ordering).

#### DO: Handle Errors Gracefully
```swift
// ✅ GOOD - Specific error handling
do {
    let result = try await pipeline.execute(command, context: context)
} catch PipelineError.timeout {
    // Handle timeout specifically
    await metrics.recordCounter(name: "command.timeout")
} catch PipelineError.validation(let field, let reason) {
    // Handle validation error with details
    logger.warning("Validation failed for \(field): \(reason)")
} catch {
    // Generic fallback
    logger.error("Unexpected error: \(error)")
}

// ❌ BAD - Generic catch-all
do {
    let result = try await pipeline.execute(command, context: context)
} catch {
    print("Error: \(error)") // Too generic!
}
```

#### DO: Use Type-Safe Context Keys
```swift
// ✅ GOOD - Type-safe keys
extension ContextKeys {
    static let apiVersion = ContextKey<String>("api-version")
    static let requestSource = ContextKey<RequestSource>("request-source")
}

context.apiVersion = "v2"
let version = context.apiVersion

// ❌ BAD - String-based keys with casting
context.setMetadata("api-version", value: "v2")
let version = context.metadata["api-version"] as? String // Unsafe!
```

### Don't

#### DON'T: Make Handlers Stateful
```text
// ❌ BAD - Stateful handler
class BadHandler: CommandHandler {
    var requestCount = 0 // Don't store state!

    func handle(_ command: MyCommand, context: CommandContext) async throws -> Result {
        requestCount += 1 // Race condition!
        // ...
    }
}

// ✅ GOOD - Stateless handler with external state
class GoodHandler: CommandHandler {
    let metrics: MetricsCollector // Injected dependency

    func handle(_ command: MyCommand, context: CommandContext) async throws -> Result {
        await metrics.recordCounter("requests", value: 1.0, tags: [:]) // MetricsCollector.recordCounter(_:value:tags:)
        // ...
    }
}
```

#### DON'T: Block in Middleware
```text
// ❌ BAD - Blocking I/O
struct BadMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        Thread.sleep(forTimeInterval: 1.0) // Never block!
        return try await next(command, context)
    }
}

// ✅ GOOD - Async operations
struct GoodMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await Task.sleep(for: .seconds(1)) // Async sleep
        return try await next(command, context)
    }
}
```

#### DON'T: Catch and Suppress Errors in Middleware
```text
// ❌ BAD - Suppressing errors
struct BadMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            return someDefaultValue // Don't suppress errors!
        }
    }
}

// ✅ GOOD - Transform or enhance errors
struct GoodMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            await context.emitCommandFailed(type: String(describing: T.self), error: error)
            throw PipelineError.executionFailed(
                message: String(describing: error),
                context: PipelineError.ErrorContext(commandType: String(describing: T.self))
            )
        }
    }
}
```

#### DON'T: Create Massive Commands
```text
// ❌ BAD - Kitchen sink command
struct DoEverythingCommand: Command {
    let createUser: Bool
    let updateProfile: Bool
    let sendEmail: Bool
    let generateReport: Bool
    // 20 more fields... Too much!
}

// ✅ GOOD - Focused commands
struct CreateUserCommand: Command { ... }
struct UpdateProfileCommand: Command { ... }
struct SendEmailCommand: Command { ... }
// Compose with transactions or sagas if needed
```

#### DON'T: Mix Business Logic in Middleware
```text
// ❌ BAD - Business logic in middleware
struct BadMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        if let cmd = command as? CreateUserCommand {
            // Don't implement business logic here!
            if !isValidEmail(cmd.email) { ... }
            let user = User(email: cmd.email)
            database.save(user)
        }
        return try await next(command, context)
    }
}

// ✅ GOOD - Keep middleware focused on cross-cutting concerns
struct GoodMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let duration = Date().timeIntervalSince(start)
        await metrics.recordTimer("command.duration", duration: duration, tags: [:]) // MetricsCollector.recordTimer(_:duration:tags:)
        return result
    }
}
```
