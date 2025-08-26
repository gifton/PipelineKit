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
    associatedtype Result
    func execute() async throws -> Result
}
```

### Command Extensions
```swift
// Validation support
extension Command {
    func validate() throws { }
}

// Sanitization support
extension Command {
    func sanitized() throws -> Self { }
}

// Security features
extension Command {
    var sensitiveFields: [String: Any] { [:] }
    func updateSensitiveFields(_ fields: [String: Any]) { }
}
```

### Example Command
```swift
struct CreateUserCommand: Command {
    let username: String
    let email: String
    
    func execute() async throws -> User {
        // Implementation
    }
    
    func validate() throws {
        guard !username.isEmpty else {
            throw PipelineError.validation(field: "username", reason: .empty)
        }
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

### Execution Priorities
```swift
public enum ExecutionPriority: Int, Comparable, Sendable {
    case authentication = 1000
    case authorization = 900
    case validation = 800
    case rateLimit = 700
    case custom = 500
    case caching = 400
    case errorHandling = 300
    case postProcessing = 200
    case monitoring = 100
}
```

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
// Automatically calls command.validate()
```

#### Rate Limiting
```swift
let rateLimiter = RateLimitingMiddleware(
    algorithm: .tokenBucket(
        capacity: 100,
        refillRate: 10,
        refillInterval: .seconds(1)
    ),
    keyExtractor: { context in
        context.commandMetadata.userId ?? "anonymous"
    }
)
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
let pipeline = PipelineBuilder()
    .add(middleware: authenticationMiddleware)
    .add(middleware: validationMiddleware)
    .add(middleware: rateLimitingMiddleware)
    .build()

let dispatcher = CommandDispatcher(pipeline: pipeline)
let result = try await dispatcher.dispatch(command, context: context)
```

### DSL Pipeline Building
```swift
let pipeline = buildPipeline {
    // Authentication & Authorization
    authenticationMiddleware
    authorizationMiddleware
    
    // Validation & Security
    validationMiddleware
    sanitizationMiddleware
    
    // Rate Limiting
    if config.enableRateLimiting {
        rateLimitingMiddleware
    }
    
    // Caching
    cachingMiddleware
    
    // Resilience
    resilientMiddleware
    
    // Monitoring
    metricsMiddleware
    performanceMiddleware
}
```

### Advanced Pipeline Configuration
```swift
let pipeline = PipelineBuilder()
    .add(middlewares: [
        auth,
        validation,
        rateLimit
    ])
    .add(group: securityGroup)
    .configure { builder in
        if isProduction {
            builder.add(middleware: encryptionMiddleware)
        }
    }
    .optimized() // Enable chain optimization
    .build()
```

## Error Handling

### Unified Error Type
```swift
public enum PipelineError: Error, LocalizedError, Sendable {
    // Validation errors
    case validation(field: String, reason: ValidationReason)
    
    // Authorization errors
    case authorization(reason: AuthorizationReason)
    
    // Rate limiting errors
    case rateLimitExceeded(limit: Int, resetTime: Date?)
    
    // Execution errors
    case executionFailed(message: String, context: [String: String]?)
    
    // Security errors
    case securityPolicy(reason: SecurityPolicyReason)
    
    // And many more...
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
// Automatic validation via middleware
let validationMiddleware = ValidationMiddleware()

// Custom validators
struct EmailCommand: Command {
    let email: String
    
    func validate() throws {
        guard OptimizedValidators.validateEmail(email) else {
            throw PipelineError.validation(field: "email", reason: .invalidFormat)
        }
    }
}
```

### Input Sanitization
```swift
let sanitizationMiddleware = SanitizationMiddleware()

struct MessageCommand: Command {
    var message: String
    
    func sanitized() throws -> Self {
        var sanitized = self
        sanitized.message = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "<script>", with: "")
        return sanitized
    }
}
```

### Encryption
```swift
let encryptionMiddleware = EncryptionMiddleware(
    encryptionService: AESEncryptionService(key: encryptionKey)
)

// Commands can mark sensitive fields
struct PaymentCommand: Command {
    let cardNumber: String
    let cvv: String
    
    var sensitiveFields: [String: Any] {
        ["cardNumber": cardNumber, "cvv": cvv]
    }
}
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

### Pipeline Flow Tracing
```swift
let flowTracer = PipelineFlowTracer()

// Start tracing
let flowId = flowTracer.startCommandFlow(command)

// Get execution flow
let flow = await flowTracer.getExecutionFlow(id: flowId)
print("Critical path: \(flow.criticalPath)")
print("Bottlenecks: \(flow.metrics.bottlenecks)")
```

### Event Emission
```swift
// Emit custom events from middleware
await context.emitCustomEvent(
    "payment.processed",
    properties: [
        "amount": "100.00",
        "currency": "USD",
        "method": "credit_card"
    ]
)
```

### System Health Monitoring
```swift
let health = await flowTracer.getSystemHealth()
print("Active flows: \(health.activeFlows)")
print("Average execution time: \(health.averageExecutionTime)")
print("Overall health: \(health.overallHealth)")
```

## Performance & Memory

### Object Pooling
```swift
// Command context pooling
let contextPool = CommandContextPool.shared
let pooledContext = contextPool.borrow(metadata: metadata)
// Context automatically returned when deallocated

// Generic object pooling
let bufferPool = BufferPool<Data>(capacity: 1000)
let buffer = await bufferPool.acquire()
// Use buffer...
await bufferPool.release(buffer)
```

### Middleware Chain Optimization
```swift
let optimizedPipeline = PipelineBuilder()
    .add(middlewares: middlewares)
    .optimized() // Enables fast-path execution
    .build()
```

### Memory Pressure Handling
```swift
// Automatic memory pressure response
let pool = ObjectPool<ExpensiveObject>(
    maxSize: 100,
    highWaterMark: 80,
    lowWaterMark: 20,
    factory: { ExpensiveObject() }
)
// Pool automatically shrinks under memory pressure
```

## Testing Support

### Test Helpers
```swift
// Test command
let command = TestCommand(value: "test", shouldFail: false)

// Test context with metadata
let context = CommandContext.test(
    userId: "test-user",
    correlationId: "test-correlation-123"
)

// Test middleware
let testMiddleware = TestMiddleware()
try await pipeline.execute(command, context: context)
assert(testMiddleware.executionCount == 1)
```

### Mock Services
```swift
// Mock metrics collector
let mockMetrics = MockMetricsCollector()
let middleware = MetricsMiddleware(collector: mockMetrics)

// Verify metrics
let recordedMetrics = mockMetrics.recordedMetrics
assert(recordedMetrics.count == 1)
```

### Performance Testing
```swift
// Stress testing support
let scenario = BurstLoadScenario(
    name: "API Load Test",
    idleDuration: 10,
    spikeDuration: 60,
    recoveryDuration: 30
)

let runner = ScenarioRunner(
    orchestrator: orchestrator,
    safetyMonitor: safetyMonitor,
    metricCollector: metricCollector
)

try await runner.run(scenario)
```

## Thread Safety

All public APIs in PipelineKit are thread-safe and designed for concurrent use:

- Commands must be `Sendable`
- Middleware must be `Sendable`
- Context propagation is thread-safe
- All pools and caches use appropriate synchronization

