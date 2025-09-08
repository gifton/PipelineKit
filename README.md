# PipelineKit

A high-performance, type-safe command-bus architecture for Swift 6 with built‑in observability, resilience, caching, and pooling. Designed for production pipelines with strong concurrency guarantees and modular, opt‑in features.

[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS-lightgrey.svg)](Package.swift)

## Table of Contents

- [Command-Bus Architecture](#command-bus-architecture)
- [Core Types](#core-types)
- [Modules](#modules)
  - [PipelineKit (Main)](#pipelinekit-main)
  - [PipelineKitCore](#pipelinekitcore)
  - [PipelineKitObservability](#pipelinekitobservability)
  - [PipelineKitResilience](#pipelinekitresilience)
  - [PipelineKitSecurity](#pipelinekitsecurity)
  - [PipelineKitCaching](#pipelinekitcaching)
  - [PipelineKitPooling](#pipelinekitpooling)
- [Installation](#installation)
- [Example Usages](#example-usages)
- [Do's and Don'ts](#dos-and-donts)
- [Performance](#performance)
- [Contributing](#contributing)

## Command-Bus Architecture

### What is Command-Bus?

The Command-Bus pattern is a powerful architectural approach that decouples request handling from business logic execution. Instead of directly calling methods, you dispatch **Commands** (data objects representing intent) through a **Pipeline** that processes them through **Middleware** before reaching the final **Handler**.

```
Command → Pipeline → [Middleware Chain] → Handler → Result
```

### Why Command-Bus?

**Benefits:**
- **Separation of Concerns**: Commands are pure data, handlers contain logic
- **Cross-Cutting Concerns**: Middleware handles logging, validation, caching, etc.
- **Type Safety**: Full compile-time type checking with Swift generics
- **Testability**: Easy to test individual components in isolation
- **Scalability**: Add features via middleware without touching core logic
- **Observability**: Built-in hooks for metrics, tracing, and logging

### How It Works

```swift
// 1. Define a Command (what you want to do)
struct CreateUserCommand: Command {
    typealias Result = User
    let email: String
    let name: String
}

// 2. Create a Handler (how to do it)
final class CreateUserHandler: CommandHandler {
    func handle(_ command: CreateUserCommand) async throws -> User {
        // Business logic here
        return User(email: command.email, name: command.name)
    }
}

// 3. Configure Pipeline with Middleware
let pipeline = StandardPipeline(handler: CreateUserHandler())
await pipeline.addMiddleware(ValidationMiddleware())
await pipeline.addMiddleware(LoggingMiddleware())

// 4. Execute Command
let user = try await pipeline.execute(
    CreateUserCommand(email: "user@example.com", name: "Jane Doe"),
    context: CommandContext()
)
```

## Core Types

### Command

A `Command` is a simple data structure that represents an action to be performed. Commands are immutable and contain all data needed to execute the action.

```swift
protocol Command: Sendable {
    associatedtype Result: Sendable
}
```

**Key Points:**
- Must be `Sendable` for thread safety
- Contains only data, no logic
- Immutable after creation
- Type-safe result via associated type

### CommandHandler

Handlers contain the actual business logic for processing commands.

```swift
protocol CommandHandler: Sendable {
    associatedtype CommandType: Command
    func handle(_ command: CommandType) async throws -> CommandType.Result
}
```

**Key Points:**
- One handler per command type
- Stateless and `Sendable`
- Async/await native
- Focused single responsibility

### Middleware

Middleware provides cross-cutting functionality that wraps command execution.

```swift
protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }
    func execute<T: Command>(_ command: T, 
                             context: CommandContext,
                             next: (T, CommandContext) async throws -> T.Result) async throws -> T.Result
}
```

**Built-in Priorities (lower value executes earlier):**
- `.authentication` (100)
- `.validation` (200)
- `.resilience` (250)
- `.preProcessing` (300)
- `.monitoring` (350)
- `.processing` (400)
- `.postProcessing` (500)
- `.errorHandling` (600)
- `.observability` (700)
- `.custom` (1000)

Note: Equal priorities preserve insertion order (stable ordering).

### CommandContext

Thread-safe context for sharing data across middleware and handlers.

```swift
actor CommandContext {
    // Typed storage access
    func set<T: Sendable>(_ key: ContextKey<T>, value: T?)
    func get<T: Sendable>(_ key: ContextKey<T>) -> T?

    // Built‑in async properties
    var requestID: String? { get async }
    var userID: String? { get async }
    var correlationID: String? { get async }
    var metadata: [String: any Sendable] { get async }

    // Observability
    var eventEmitter: EventEmitter? { get }
    func setEventEmitter(_ emitter: EventEmitter?)
}

Event emission is provided via `PipelineKitObservability` (see that module). Core exposes the `EventEmitter` type and forwards to the configured emitter when set.
```

### Pipeline

The pipeline orchestrates command execution through middleware to handlers.

```swift
actor StandardPipeline<C: Command, H: CommandHandler> where H.CommandType == C {
    init(handler: H, maxConcurrency: Int? = nil)
    func execute(_ command: C, context: CommandContext) async throws -> C.Result
    func addMiddleware(_ middleware: any Middleware) throws
}
```

## Modules

### PipelineKit (Main)

The main module provides the core pipeline implementation with production-ready defaults.

**Key Features:**
- `StandardPipeline` and `AnyStandardPipeline` – production‑grade pipeline implementations
- `DynamicPipeline` – runtime routing with handler registry
- `PipelineBuilder` – fluent builder for assembling pipelines
- `SimpleSemaphore` – basic concurrency control (acquire is `async throws`)
- `NextGuard` – ensures middleware `next` is called exactly once
- `NextGuardWarningSuppressing` – opt‑in to suppress debug‑only warnings for intentional short‑circuits (e.g., cache hits)

SwiftLog is used for internal logging; on Apple, you can bootstrap `swift-log-oslog` for OSLog output.

```swift
import PipelineKit

// Basic pipeline
let pipeline = StandardPipeline(handler: MyHandler())

// With concurrency limit
let pipeline = StandardPipeline(handler: MyHandler(), maxConcurrency: 10)
```

### PipelineKitCore

Foundation types and protocols that all other modules build upon.

**Components:**
- Core protocols (`Command`, `CommandHandler`, `Middleware`, `Pipeline`)
- `ExecutionPriority` and stable middleware ordering
- `CommandContext` (typed storage, built‑ins, fork, cancellation)
- `PipelineError`, `RetryPolicy`, `DelayStrategy`
- Events: `PipelineEvent` (monotonic `sequenceID`), `EventEmitter` / `PipelineObserver`
- Utilities: memory pressure detection and profiling

```swift
import PipelineKitCore

struct MyCommand: Command {
    typealias Result = String
    let input: String
}

final class MyHandler: CommandHandler {
    func handle(_ command: MyCommand) async throws -> String {
        "Processed: \(command.input)"
    }
}
```

### PipelineKitObservability

Comprehensive observability with metrics, events, and distributed tracing.

**Features:**
- `ObservabilitySystem` – unified events + metrics orchestration
- StatsD exporter (UDP) with batching and sampling
- `EventHub` ↔ `MetricsStorage` integration (events can produce metrics)
- `LoggingEmitter` – logs events via OSLog (Apple) or print/SwiftLog elsewhere

Note: The default UDP transport uses Apple’s Network framework when available; on non‑Apple platforms you can plug in a different transport.

```swift
import PipelineKitObservability

// Production setup
let observability = await ObservabilitySystem.production(
    statsdHost: "localhost",
    statsdPort: 8125,
    prefix: "myapp"
)

// Automatic metrics from events
context.emitCommandCompleted(type: "CreateUser", duration: 0.125)
// Generates: 
// - counter: command.completed = 1
// - timer: command.duration = 125ms

// Direct metrics
await observability.recordGauge(name: "queue.depth", value: 42)
await observability.recordCounter(name: "api.requests", value: 1)
await observability.recordTimer(name: "db.query", duration: 0.050)
```

### PipelineKitResilience

Production-grade resilience patterns for handling failures and load.

**Components:**

#### BackPressure
Controls system load with sophisticated queueing:
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

#### Circuit Breaker
Prevents cascading failures:
```swift
let breaker = CircuitBreakerMiddleware(
    failureThreshold: 5,
    resetTimeout: 30.0,
    halfOpenLimit: 3
)
```

#### Timeout
Prevents hanging operations:
```swift
let timeout = TimeoutMiddleware(
    defaultTimeout: 5.0,
    perCommandTimeouts: [
        "SlowCommand": 30.0
    ]
)
```

#### Retry
Automatic retry with backoff:
```swift
let retry = RetryMiddleware(
    maxAttempts: 3,
    backoff: .exponential(base: 2.0, maxDelay: 30.0),
    retryableErrors: [NetworkError.self]
)
```

#### Bulkhead
Isolates resources:
```swift
let bulkhead = BulkheadMiddleware(maxConcurrent: 10)
```

### PipelineKitSecurity

Security middleware for authentication, authorization, and audit.

**Features:**

#### Authentication
```swift
let auth = AuthenticationMiddleware { context in
    guard let token = context.metadata["auth-token"] as? String else {
        throw SecurityError.unauthorized
    }
    let user = try await validateToken(token)
    await context.setUserID(user.id)
}
```

#### Authorization
```swift
let authz = AuthorizationMiddleware { command, context in
    guard let userID = await context.userID else {
        return false
    }
    return await checkPermission(userID, for: command)
}
```

#### Audit Logging
```swift
let audit = AuditLoggingMiddleware(
    logger: FileAuditLogger(path: "/var/log/audit.log"),
    events: [.commandExecuted, .authenticationFailed, .authorizationDenied]
)
```

### PipelineKitCache

Intelligent caching with automatic invalidation and compression.

**Features:**
```swift
let cache = CachingMiddleware(
    storage: RedisCache(),
    keyStrategy: .commandBased,
    ttl: 300,
    compression: .gzip
)

// Automatic caching based on command type
pipeline.addMiddleware(cache)
```

Additional wrappers: `CachedMiddleware`, `ConditionalCachedMiddleware`, and in‑memory cache implementations for middleware or general data.

### PipelineKitPooling

Object pooling for high-performance resource management.

**Features:**
```swift
let pool = ObjectPool<DatabaseConnection>(
    configuration: ObjectPoolConfiguration(
        maxSize: 50,
        highWaterMark: 40,
        lowWaterMark: 10
    ),
    factory: { DatabaseConnection() },
    reset: { conn in await conn.reset() }
)

// Automatic resource management
let connection = try await pool.acquire()
defer { await pool.release(connection) }
// Use connection...
```

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.1.0")
]
```

Then add the modules you need:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            "PipelineKit",
            "PipelineKitObservability",
            "PipelineKitResilience"
        ]
    )
]
```

## Example Usages

### Basic Example

```swift
import PipelineKit

// 1. Define Command
struct CalculateCommand: Command {
    typealias Result = Double
    let a: Double
    let b: Double
    let operation: String
}

// 2. Create Handler
final class CalculatorHandler: CommandHandler {
    func handle(_ command: CalculateCommand) async throws -> Double {
        switch command.operation {
        case "+": return command.a + command.b
        case "-": return command.a - command.b
        case "*": return command.a * command.b
        case "/": 
            guard command.b != 0 else { throw CalculationError.divisionByZero }
            return command.a / command.b
        default:
            throw CalculationError.unknownOperation
        }
    }
}

// 3. Use Pipeline
let pipeline = StandardPipeline(handler: CalculatorHandler())
let result = try await pipeline.execute(
    CalculateCommand(a: 10, b: 5, operation: "+"),
    context: CommandContext()
)
print(result) // 15.0
```

### Production Example with Full Stack

```swift
import PipelineKit
import PipelineKitObservability
import PipelineKitResilience
import PipelineKitSecurity
import PipelineKitCaching

// Configure observability
let observability = await ObservabilitySystem.production(
    statsdHost: "metrics.internal",
    statsdPort: 8125
)

// Create pipeline with handler
let pipeline = StandardPipeline(
    handler: CreateOrderHandler(),
    maxConcurrency: 100 // Limit concurrent orders
)

// Add security middleware (order matters!)
try await pipeline.addMiddleware(
    AuthenticationMiddleware(validator: TokenValidator())
)
try await pipeline.addMiddleware(
    AuthorizationMiddleware(policy: OrderPolicy())
)
try await pipeline.addMiddleware(
    AuditLoggingMiddleware(logger: productionLogger)
)

// Add resilience middleware
try await pipeline.addMiddleware(
    TimeoutMiddleware(defaultTimeout: 10.0)
)
try await pipeline.addMiddleware(
    RetryMiddleware(maxAttempts: 3, backoff: .exponential())
)
try await pipeline.addMiddleware(
    CircuitBreakerMiddleware(failureThreshold: 5)
)

// Add caching for read operations
try await pipeline.addMiddleware(
    CachingMiddleware(
        storage: RedisCache(),
        shouldCache: { command in command is GetOrderCommand }
    )
)

// Execute with context
let context = CommandContext()
await context.setRequestID(UUID().uuidString)
await context.setMetadata("auth-token", value: request.token)
context.eventEmitter = observability.eventHub

let order = try await pipeline.execute(
    CreateOrderCommand(items: items, userId: userId),
    context: context
)
```

### Async Event Processing Example

```swift
// Event-driven command processing
actor EventProcessor {
    let pipeline: StandardPipeline<ProcessEventCommand, ProcessEventHandler>
    
    func processEvents(_ events: AsyncStream<Event>) async {
        await withTaskGroup(of: Void.self) { group in
            for await event in events {
                group.addTask { [pipeline] in
                    let context = CommandContext()
                    await context.setCorrelationID(event.correlationId)
                    
                    do {
                        _ = try await pipeline.execute(
                            ProcessEventCommand(event: event),
                            context: context
                        )
                        await context.emitCommandCompleted(
                            type: "ProcessEvent",
                            duration: Date().timeIntervalSince(event.timestamp)
                        )
                    } catch {
                        await context.emitCommandFailed(
                            type: "ProcessEvent",
                            error: error
                        )
                    }
                }
            }
        }
    }
}
```

## Do's and Don'ts

### ✅ DO's

#### DO: Keep Commands Simple and Immutable
```swift
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
await context.setRequestID(UUID().uuidString)
await context.setUserID(authenticatedUser.id)
await context.setMetadata("client-version", value: "2.0.0")

// ❌ BAD - Passing auth in every command
struct MyCommand: Command {
    let authToken: String // Don't duplicate auth in every command!
    let userId: String // Use context instead!
}
```

#### DO: Order Middleware Correctly
```swift
// ✅ GOOD - Correct order
pipeline.addMiddleware(AuthenticationMiddleware())    // First: Who are you?
pipeline.addMiddleware(AuthorizationMiddleware())     // Second: Can you do this?
pipeline.addMiddleware(ValidationMiddleware())        // Third: Is the data valid?
pipeline.addMiddleware(CachingMiddleware())          // Fourth: Check cache
pipeline.addMiddleware(LoggingMiddleware())          // Last: Log everything

// ❌ BAD - Wrong order
pipeline.addMiddleware(CachingMiddleware())          // Cache before auth? No!
pipeline.addMiddleware(AuthenticationMiddleware())   // Too late!
```

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
extension ContextKey {
    static let apiVersion = ContextKey<String>("api-version")
    static let requestSource = ContextKey<RequestSource>("request-source")
}

await context.set(.apiVersion, value: "v2")
let version = await context.value(for: .apiVersion) // String?

// ❌ BAD - String-based keys with casting
await context.setMetadata("api-version", value: "v2")
let version = context.metadata["api-version"] as? String // Unsafe!
```

### ❌ DON'Ts

#### DON'T: Make Handlers Stateful
```swift
// ❌ BAD - Stateful handler
class BadHandler: CommandHandler {
    var requestCount = 0 // Don't store state!
    
    func handle(_ command: MyCommand) async throws -> Result {
        requestCount += 1 // Race condition!
        // ...
    }
}

// ✅ GOOD - Stateless handler with external state
class GoodHandler: CommandHandler {
    let metrics: MetricsCollector // Injected dependency
    
    func handle(_ command: MyCommand) async throws -> Result {
        await metrics.incrementCounter("requests")
        // ...
    }
}
```

#### DON'T: Block in Middleware
```swift
// ❌ BAD - Blocking I/O
struct BadMiddleware: Middleware {
    func execute<T>(_ command: T, context: CommandContext, next: Next) async throws -> T.Result {
        Thread.sleep(forTimeInterval: 1.0) // Never block!
        return try await next(command, context)
    }
}

// ✅ GOOD - Async operations
struct GoodMiddleware: Middleware {
    func execute<T>(_ command: T, context: CommandContext, next: Next) async throws -> T.Result {
        try await Task.sleep(for: .seconds(1)) // Async sleep
        return try await next(command, context)
    }
}
```

#### DON'T: Catch and Suppress Errors in Middleware
```swift
// ❌ BAD - Suppressing errors
struct BadMiddleware: Middleware {
    func execute<T>(_ command: T, context: CommandContext, next: Next) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            return someDefaultValue // Don't suppress errors!
        }
    }
}

// ✅ GOOD - Transform or enhance errors
struct GoodMiddleware: Middleware {
    func execute<T>(_ command: T, context: CommandContext, next: Next) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            await context.emitCommandFailed(type: String(describing: T.self), error: error)
            throw PipelineError.wrapped(error, context: extractContext(from: context))
        }
    }
}
```

#### DON'T: Create Massive Commands
```swift
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
```swift
// ❌ BAD - Business logic in middleware
struct BadMiddleware: Middleware {
    func execute<T>(_ command: T, context: CommandContext, next: Next) async throws -> T.Result {
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
    func execute<T>(_ command: T, context: CommandContext, next: Next) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let duration = Date().timeIntervalSince(start)
        await metrics.recordTimer("command.duration", value: duration)
        return result
    }
}
```

## Performance

PipelineKit is designed for high-throughput, low-latency scenarios:

### Benchmarks (M2 Pro)

| Operation | Throughput | Latency (p99) |
|-----------|------------|---------------|
| Simple Pipeline | 1.2M ops/sec | < 1μs |
| With 5 Middleware | 800K ops/sec | < 2μs |
| With BackPressure | 500K ops/sec | < 5μs |
| With Full Stack | 200K ops/sec | < 10μs |

### Memory Efficiency

- **Zero-allocation hot path** for simple commands
- **Object pooling** for expensive resources
- **Automatic memory pressure handling**
- **Concurrent-safe with minimal locking**

### Optimization Tips

1. **Use object pools** for expensive resources
2. **Enable caching** for read-heavy workloads
3. **Set appropriate concurrency limits**
4. **Use priority queues** for critical operations
5. **Monitor with built-in metrics**

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Development Setup

```bash
git clone https://github.com/gifton/PipelineKit.git
cd PipelineKit
swift build
swift test
```

### Running Benchmarks

```bash
swift package benchmark
```

### Code Quality

```bash
swiftlint lint --strict
swift-format lint --recursive Sources Tests
```

## License

PipelineKit is released under the MIT License. See [LICENSE](LICENSE) for details.

---

## Additional Notes

- SimpleSemaphore: `acquire()` is `async throws` and returns a `SemaphoreToken` that auto‑releases on deinit; you can also `defer { token.release() }` explicitly.
- DynamicPipeline registration APIs:
  - `register(_:handler:)` – replace‑by‑default (non‑throwing)
  - `registerOnce(_:handler:)` – throws if a handler already exists
  - `replace(_:with:)` – returns whether a previous handler was replaced
  - `unregister(_:)` – returns whether a handler was removed
- NextGuard safety:
  - Default: ensures `next` is called exactly once; throws on multiple/concurrent calls.
  - `UnsafeMiddleware`: opt‑out for custom patterns (use with care).
  - `NextGuardWarningSuppressing`: suppresses debug‑only deinit warnings for intentional short‑circuits (e.g., cache hits).
- AnySendable: type‑erased Sendable value container (not Equatable/Hashable by design). Extract concrete values via `get(_:)` to compare.
- Platform support:
  - Apple platforms fully supported per Package.swift.
  - SwiftLog is used for internal logging; on Apple you can bootstrap OSLog backend via `swift-log-oslog` if desired.
  - Linux builds are enabled; some transports (e.g., Network‑based UDP) may require alternative backends.

## Acknowledgments

Built with ❤️ using Swift 6 and modern concurrency patterns.

Special thanks to the Swift community for inspiration and feedback.
