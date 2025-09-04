# PipelineKit API Documentation

PipelineKit is a comprehensive Swift framework for building secure, observable, and resilient command execution pipelines.

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Command Protocol](#command-protocol)
3. [Middleware System](#middleware-system)
4. [Pipeline Building](#pipeline-building)
5. [Error Handling](#error-handling)
6. [Security Features](#security-features)
7. [Observability](#observability)
8. [Performance & Memory](#performance--memory)
9. [Testing Support](#testing-support)

## Core Concepts

### Command Pattern
The foundation of PipelineKit is the Command pattern, where each operation is encapsulated as a command object.

### Middleware Pipeline
Commands flow through a configurable pipeline of middleware that can modify, validate, observe, or enhance command execution.

### Context Propagation
A thread-safe context object carries metadata and cross-cutting concerns through the pipeline.

## Command Protocol

### Basic Command
```swift
public protocol Command: Sendable {
    associatedtype Result: Sendable
}
```

### CommandHandler
```swift
public protocol CommandHandler: Sendable {
    associatedtype CommandType: Command
    func handle(_ command: CommandType) async throws -> CommandType.Result
}
```

### Example Command + Handler
```swift
struct CreateUserCommand: Command {
    typealias Result = User
    let username: String
    let email: String
}

final class CreateUserHandler: CommandHandler {
    typealias CommandType = CreateUserCommand
    func handle(_ command: CreateUserCommand) async throws -> User {
        // Validate and implement
        return User(username: command.username, email: command.email)
    }
}
```

## Middleware System

### Middleware Protocol
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

### Execution Priorities (lower executes earlier)
```swift
public enum ExecutionPriority: Int, Sendable, CaseIterable {
    case authentication = 100
    case validation = 200
    case resilience = 250
    case preProcessing = 300
    case monitoring = 350
    case processing = 400
    case postProcessing = 500
    case errorHandling = 600
    case observability = 700
    case custom = 1000
}
```
Equal priorities preserve insertion order (stable ordering).

### Built-in Middleware

#### Authentication & Authorization
```swift
// Authentication middleware
let authMiddleware = AuthenticationMiddleware { context in
    // Verify user credentials
    return AuthenticatedUser(id: "123", roles: ["user"])
}

// Authorization middleware
let authzMiddleware = AuthorizationMiddleware(
    policy: RoleBasedPolicy(requiredRoles: ["admin"])
)
```

#### Validation
```swift
let validationMiddleware = ValidationMiddleware()
```

#### Rate Limiting
```swift
let limiter = RateLimiter(
    strategy: .tokenBucket(capacity: 100, refillRate: 10),
    scope: .perUser
)
let rateLimitMiddleware = RateLimitingMiddleware(limiter: limiter)
```

#### Caching
```swift
let cache = InMemoryCache(maxSize: 1000)
let cachingMiddleware = CachingMiddleware(
    cache: cache,
    keyGenerator: { command in
        "\(type(of: command))-\(command.hashValue)"
    },
    ttl: 300 // 5 minutes
)
```

#### Resilience
```swift
let resilientMiddleware = ResilientMiddleware(
    name: "api-commands",
    retryPolicy: RetryPolicy(
        maxAttempts: 3,
        delayStrategy: .exponentialBackoff(
            baseDelay: 0.1,
            maxDelay: 5.0,
            multiplier: 2.0
        )
    ),
    circuitBreaker: CircuitBreaker(
        name: "api-circuit",
        failureThreshold: 5,
        timeout: 60
    )
)
```

#### Metrics & Monitoring
```swift
let metricsMiddleware = MetricsMiddleware(
    collector: metricsCollector,
    namespace: "commands",
    includeCommandType: true
)

let performanceMiddleware = PerformanceMiddleware(
    collector: performanceCollector,
    includeDetailedMetrics: true
)
```

## Pipeline Building

### Basic Pipeline
```swift
let pipeline = StandardPipeline(handler: CreateUserHandler())
try pipeline.addMiddleware(AuthenticationMiddleware(...))
try pipeline.addMiddleware(ValidationMiddleware())

let result = try await pipeline.execute(
    CreateUserCommand(username: "u", email: "e"),
    context: CommandContext()
)
```

### Builder (Fluent)
```swift
let builder = PipelineBuilder(handler: CreateUserHandler())
    .with(AuthenticationMiddleware(...))
    .with(ValidationMiddleware())
let pipeline = try await builder.build()
```

### Dynamic Routing
```swift
let bus = DynamicPipeline()
await bus.register(CreateUserCommand.self, handler: CreateUserHandler())
let user = try await bus.send(CreateUserCommand(username: "u", email: "e"))
```

#### Registration Policy
```swift
// Replace-by-default (non-throwing)
await bus.register(CreateUserCommand.self, handler: CreateUserHandler())

// Register once (throws if a handler already exists)
try await bus.registerOnce(CreateUserCommand.self, handler: CreateUserHandler())

// Replace (returns whether a previous handler was replaced)
let replaced = await bus.replace(CreateUserCommand.self, with: CreateUserHandler())

// Unregister (returns whether a handler was removed)
let removed = await bus.unregister(CreateUserCommand.self)
```

## Error Handling

### Unified Error Type (selected cases)
```swift
public enum PipelineError: Error, LocalizedError, Sendable {
    // Validation
    case validation(field: String?, reason: ValidationReason)

    // Authorization
    case authorization(reason: AuthorizationReason)

    // Rate limiting
    case rateLimitExceeded(limit: Int, resetTime: Date?, retryAfter: TimeInterval?)

    // Execution / Middleware
    case executionFailed(message: String, context: ErrorContext?)
    case middlewareError(middleware: String, message: String, context: ErrorContext?)

    // Timeout / Cancellation
    case timeout(duration: TimeInterval, context: ErrorContext?)
    case cancelled(context: String?)
}

public struct ErrorContext: Sendable {
    public let commandType: String
    public let middlewareType: String?
    public let correlationId: String?
    public let userId: String?
    public let additionalInfo: [String: String]
    public let timestamp: Date
    public let stackTrace: [String]?
}
```

### Error Recovery
```swift
public protocol ErrorRecovery: Sendable {
    associatedtype RecoveryCommand: Command
    
    func canRecover(from error: Error, context: ErrorRecoveryContext) -> Bool
    func recover(from error: Error, context: ErrorRecoveryContext) async throws -> RecoveryCommand
}
```

## Security Features

### Command Validation
```swift
// Validation via middleware
let validationMiddleware = ValidationMiddleware()
try pipeline.addMiddleware(validationMiddleware)
```

### Input Sanitization
```swift
let sanitizationMiddleware = SanitizationMiddleware()
try pipeline.addMiddleware(sanitizationMiddleware)
```

### Encryption
```swift
let encryptionService = StandardEncryptionService(keyStore: myKeyStore)
let encryptionMiddleware = EncryptionMiddleware(encryptionService: encryptionService)
try pipeline.addMiddleware(encryptionMiddleware)
```

### Security Policies
```swift
let securityPolicy = SecurityPolicy(
    maxCommandSize: 1_048_576, // 1MB
    maxStringLength: 10_000,
    allowedCharacterSet: .alphanumerics,
    maxExecutionTime: 30.0,
    maxMemoryUsage: 100_000_000 // 100MB
)

let securityMiddleware = SecurityPolicyMiddleware(policy: securityPolicy)
```

## Observability

Use `ObservabilitySystem` to connect events and metrics naturally.

```swift
import PipelineKitObservability

// Create unified system
let observability = await ObservabilitySystem.production(
    statsdHost: "metrics.internal",
    statsdPort: 8125,
    prefix: "myapp"
)

// Configure context to emit events
let context = CommandContext()
await context.setEventEmitter(observability.eventHub)

// Emit events explicitly
await context.emitEvent("command.started", properties: [
    "commandType": String(describing: CreateUserCommand.self)
])
await context.emitCommandCompleted(type: "CreateUser")

// Record direct metrics
await observability.recordCounter(name: "api.requests", value: 1)
await observability.recordTimer(name: "db.query", duration: 0.050)
```

## Performance & Memory

### Object Pooling
```swift
import PipelineKitPooling

// Create a pool for expensive objects
let pool = ObjectPool(
    configuration: .default,
    factory: { ExpensiveObject() },
    reset: { $0.reset() }
)

let obj = try await pool.acquire()
defer { await pool.release(obj) }
// Use obj...
```

### Memory Pressure Handling
```swift
// Start monitoring once at app startup
await MemoryPressureDetector.shared.startMonitoring()

// Register a cleanup handler
let handlerId = await MemoryPressureDetector.shared.register {
    // Release cached resources
    await pool.releaseUnused()
}
```

## Testing Support

### Event Capture
```swift
import PipelineKitTestSupport

let emitter = CapturingEmitter()
let context = CommandContext()
await context.setEventEmitter(emitter)

// Execute code that emits events
// ...

let events = await emitter.events
XCTAssertGreaterThan(events.count, 0)
```

### Middleware Testing
```swift
import PipelineKitTestSupport

final class LoggingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        return try await next(command, context)
    }
}

let pipeline = StandardPipeline(handler: CreateUserHandler())
try pipeline.addMiddleware(LoggingMiddleware())
let _ = try await pipeline.execute(CreateUserCommand(username: "u", email: "e"), context: CommandContext())
```

## Thread Safety

All public APIs in PipelineKit are thread-safe and designed for concurrent use:

- Commands must be `Sendable`
- Middleware must be `Sendable`
- Context propagation is thread-safe
- All pools and caches use appropriate synchronization
