# PipelineKit

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%20|%20iOS%20|%20watchOS%20|%20tvOS%20|%20Linux-lightgrey.svg)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A comprehensive, security-first Command-Pipeline architecture framework for Swift 6, featuring full concurrency support, robust middleware chains, and enterprise-grade security features.

## 🌟 Features

### Core Architecture
- **Command Pattern**: Type-safe command execution with result handling
- **Pipeline/Filter Pattern**: Composable middleware chains for request processing
- **Swift 6 Concurrency**: Full `async`/`await` support with `Sendable` conformance
- **Thread Safety**: Actor-based isolation for concurrent operations
- **Context-Aware Pipelines**: State sharing between middleware components

### Security Features
- **🔒 Input Validation**: Comprehensive validation rules with custom validators
- **🧹 Data Sanitization**: HTML, SQL injection, and XSS protection
- **👮 Authorization**: Role-based access control with flexible rules
- **🚦 Rate Limiting**: Token bucket, sliding window, and adaptive strategies
- **⚡ Circuit Breaker**: Failure protection with automatic recovery
- **📊 Audit Logging**: Complete command execution tracking with privacy controls
- **🔐 Encryption**: AES-GCM encryption for sensitive data with key rotation
- **🛡️ Secure Error Handling**: Information leakage prevention

### Advanced Features
- **Middleware Ordering**: 51 predefined execution orders for security compliance
- **Concurrent Execution**: Parallel pipeline processing with load balancing
- **Priority Queues**: Weighted command execution for performance optimization
- **DoS Protection**: Multi-layer defense against denial-of-service attacks

## 🚀 Quick Start

### Installation

Add PipelineKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourorg/PipelineKit", from: "1.0.0")
]
```

### Basic Usage

```swift
import PipelineKit

// Define a command
struct CreateUserCommand: Command {
    let email: String
    let username: String
    
    typealias Result = User
}

// Create a handler
struct CreateUserHandler: CommandHandler {
    func handle(_ command: CreateUserCommand) async throws -> User {
        // Validate and create user
        return User(email: command.email, username: command.username)
    }
}

// Set up the command bus
let bus = CommandBus()
await bus.register(CreateUserCommand.self, handler: CreateUserHandler())

// Execute commands
let user = try await bus.send(
    CreateUserCommand(email: "user@example.com", username: "johndoe")
)
```

### Secure Pipeline Example

```swift
import PipelineKit

// Create a secure pipeline with ordered middleware
let secureBuilder = SecurePipelineBuilder()
    .add(ValidationMiddleware())
    .add(AuthorizationMiddleware(roles: ["admin", "user"]))
    .add(RateLimitingMiddleware(
        limiter: RateLimiter(
            strategy: .tokenBucket(capacity: 100, refillRate: 10)
        )
    ))
    .add(AuditLoggingMiddleware(
        logger: AuditLogger(destination: .file(url: auditLogURL))
    ))

let pipeline = secureBuilder.build()

// Execute with security middleware
let result = try await pipeline.execute(
    command,
    metadata: DefaultCommandMetadata(userId: "user123")
)
```

## 📖 Comprehensive Examples

### 1. Command with Validation

```swift
struct PaymentCommand: Command, ValidatableCommand {
    let amount: Double
    let cardNumber: String
    let email: String
    
    typealias Result = PaymentResult
    
    func validate() throws {
        try Validator.notEmpty(cardNumber, field: "cardNumber")
        try Validator.email(email)
        try Validator.range(amount, min: 0.01, max: 10000, field: "amount")
    }
}
```

### 2. Encrypted Sensitive Data

```swift
struct PaymentCommand: Command, EncryptableCommand {
    var cardNumber: String
    var cvv: String
    let amount: Double
    
    typealias Result = PaymentResult
    
    var sensitiveFields: [String: Any] {
        ["cardNumber": cardNumber, "cvv": cvv]
    }
    
    mutating func updateSensitiveFields(_ fields: [String: Any]) {
        if let cardNumber = fields["cardNumber"] as? String {
            self.cardNumber = cardNumber
        }
        if let cvv = fields["cvv"] as? String {
            self.cvv = cvv
        }
    }
}

// Usage with encryption
let encryptor = CommandEncryptor()
let encrypted = try await encryptor.encrypt(paymentCommand)
let decrypted = try await encryptor.decrypt(encrypted)
```

### 3. Context-Aware Processing

```swift
// Define context keys
struct UserKey: ContextKey {
    typealias Value = User
}

struct MetricsKey: ContextKey {
    typealias Value = RequestMetrics
}

// Create context-aware middleware
struct AuthenticationMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Authenticate and store user in context
        let user = try await authenticate(command)
        await context.set(UserKey.self, value: user)
        
        return try await next(command, context)
    }
}
```

### 4. Rate Limiting and Circuit Breaking

```swift
// Configure rate limiter
let rateLimiter = RateLimiter(
    strategy: .adaptive(
        baseRate: 100,
        loadFactor: { await systemLoad() }
    ),
    scope: .perUser
)

// Configure circuit breaker
let circuitBreaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: 30.0
)

// Secure dispatcher with both
let dispatcher = SecureCommandDispatcher(
    bus: bus,
    rateLimiter: rateLimiter,
    circuitBreaker: circuitBreaker
)
```

### 5. Audit Logging

```swift
// Configure audit logger
let auditLogger = AuditLogger(
    destination: .file(url: URL(fileURLWithPath: "/var/log/commands.json")),
    privacyLevel: .masked,
    bufferSize: 1000
)

// Query audit logs
let criteria = AuditQueryCriteria(
    startDate: Date().addingTimeInterval(-3600), // Last hour
    userId: "user123",
    success: false // Failed commands only
)

let failedCommands = await auditLogger.query(criteria)

// Generate statistics
let stats = AuditStatistics.calculate(from: failedCommands)
print("Failure rate: \(1.0 - stats.successRate)")
```

## 🏗️ Architecture

### Command Flow

```
Request → Validation → Authorization → Rate Limiting → Business Logic → Audit → Response
```

## 🔧 Pipeline Types

PipelineKit provides multiple pipeline implementations, each optimized for different use cases:

### 1. **Basic Pipeline** - Sequential Processing

The fundamental pipeline executes middleware sequentially in a single thread.

**Best for:**
- Simple command processing
- Development and testing
- Low-complexity operations
- When order is critical

```swift
let pipeline = Pipeline()
    .use(ValidationMiddleware())
    .use(AuthorizationMiddleware())
    .use(AuditLoggingMiddleware())

// Sequential execution: Validation → Authorization → Audit → Handler
let result = try await pipeline.execute(command, metadata: metadata)
```

**Characteristics:**
- ✅ Predictable execution order
- ✅ Simple debugging
- ✅ Low memory overhead
- ❌ No parallelization
- ❌ Slower for I/O-heavy operations

---

### 2. **Concurrent Pipeline** - Parallel Processing

Executes independent middleware concurrently for improved performance.

**Best for:**
- I/O-heavy operations
- Independent middleware (validation, logging)
- High-throughput scenarios
- CPU-intensive tasks

```swift
let concurrentPipeline = ConcurrentPipeline(maxConcurrency: 4)
    .use(ValidationMiddleware())      // Can run in parallel
    .use(ExternalAPIMiddleware())     // Can run in parallel
    .use(DatabaseMiddleware())        // Can run in parallel
    .use(NotificationMiddleware())    // Must run after others

// Parallel execution where possible
let result = try await concurrentPipeline.execute(command, metadata: metadata)
```

**Characteristics:**
- ✅ Faster execution for independent operations
- ✅ Better resource utilization
- ✅ Configurable concurrency limits
- ❌ More complex error handling
- ❌ Harder to debug race conditions

---

### 3. **Priority Pipeline** - Weighted Execution

Routes commands based on priority levels with weighted processing.

**Best for:**
- SLA-based processing
- VIP user prioritization
- Emergency command handling
- Resource-constrained environments

```swift
let priorityPipeline = PriorityPipeline()

// High priority: Emergency operations, VIP users
priorityPipeline.addQueue(priority: .high, weight: 70)

// Medium priority: Standard operations
priorityPipeline.addQueue(priority: .medium, weight: 20) 

// Low priority: Background tasks, cleanup
priorityPipeline.addQueue(priority: .low, weight: 10)

// Commands are processed based on priority
let highPriorityCommand = PaymentCommand(amount: 10000, priority: .high)
let result = try await priorityPipeline.execute(highPriorityCommand, metadata: metadata)
```

**Characteristics:**
- ✅ Fair resource allocation
- ✅ SLA compliance
- ✅ Starvation prevention
- ❌ More complex configuration
- ❌ Potential latency for low-priority items

---

### 4. **Context-Aware Pipeline** - State Sharing

Enables middleware to share state through a command context.

**Best for:**
- Multi-step authentication flows
- Request correlation tracking
- Metrics collection across middleware
- Complex business logic requiring state

```swift
let contextPipeline = ContextAwarePipeline()
    .use(RequestIdMiddleware())       // Sets request ID in context
    .use(AuthenticationMiddleware())  // Sets user in context
    .use(AuthorizationMiddleware())   // Uses user from context
    .use(MetricsMiddleware())         // Collects timing data

// Context is shared between all middleware
let result = try await contextPipeline.execute(command, initialContext: [:])
```

**Context Usage Example:**
```swift
struct UserKey: ContextKey {
    typealias Value = User
}

struct AuthenticationMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let user = try await authenticateUser(command)
        await context.set(UserKey.self, value: user)  // Store for other middleware
        return try await next(command, context)
    }
}

struct AuthorizationMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        guard let user = await context.get(UserKey.self) else {
            throw AuthorizationError.unauthenticated
        }
        // Use the user from context for authorization
        try await authorizeUser(user, for: command)
        return try await next(command, context)
    }
}
```

**Characteristics:**
- ✅ Rich inter-middleware communication
- ✅ Type-safe context access
- ✅ Perfect for complex flows
- ❌ Higher memory usage
- ❌ More complex middleware implementation

---

### 5. **Secure Pipeline** - Security-First Design

Pre-configured pipeline with security middleware in the correct order.

**Best for:**
- Production applications
- Financial services
- Healthcare systems
- Any security-sensitive application

```swift
let securePipeline = SecurePipelineBuilder()
    .add(ValidationMiddleware())           // Order: 300
    .add(AuthenticationMiddleware())       // Order: 100
    .add(AuthorizationMiddleware())        // Order: 200
    .add(RateLimitingMiddleware())         // Order: 320
    .add(SanitizationMiddleware())         // Order: 310
    .add(AuditLoggingMiddleware())         // Order: 800
    .build()  // Automatically sorts by security order

// Middleware executes in security-compliant order regardless of add() sequence
```

**Characteristics:**
- ✅ Automatic security ordering
- ✅ Production-ready defaults
- ✅ Comprehensive protection
- ❌ Less flexibility in ordering
- ❌ Higher overhead

---

## 🎯 Choosing the Right Pipeline

### Decision Matrix

| Use Case | Basic | Concurrent | Priority | Context-Aware | Secure |
|----------|-------|------------|----------|---------------|--------|
| **Simple CRUD** | ✅ | ❌ | ❌ | ❌ | ⚠️ |
| **High Throughput** | ❌ | ✅ | ⚠️ | ❌ | ⚠️ |
| **VIP Processing** | ❌ | ❌ | ✅ | ❌ | ⚠️ |
| **Complex Flows** | ❌ | ❌ | ❌ | ✅ | ⚠️ |
| **Production App** | ❌ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **Financial Services** | ❌ | ❌ | ❌ | ❌ | ✅ |
| **Microservices** | ❌ | ✅ | ⚠️ | ✅ | ✅ |

**Legend:** ✅ Recommended | ⚠️ Consider | ❌ Not Recommended

### Performance Characteristics

```
Latency (Lower is Better):
Basic < Context-Aware < Priority < Secure < Concurrent

Throughput (Higher is Better):
Concurrent > Priority > Basic > Context-Aware > Secure

Memory Usage (Lower is Better):
Basic < Priority < Concurrent < Secure < Context-Aware

Security (Higher is Better):
Secure > Context-Aware > Priority > Basic > Concurrent
```

### Real-World Examples

#### E-commerce Platform
```swift
// Product search (high volume, low security)
let searchPipeline = ConcurrentPipeline()
    .use(CacheMiddleware())
    .use(SearchMiddleware())

// Payment processing (high security, priority)
let paymentPipeline = SecurePipelineBuilder()
    .add(PriorityMiddleware())  // VIP customers first
    .add(ValidationMiddleware())
    .add(AuthorizationMiddleware())
    .add(EncryptionMiddleware())
    .add(PaymentMiddleware())
    .build()
```

#### Healthcare System
```swift
// Patient record access (context-aware for audit trail)
let patientPipeline = ContextAwarePipeline()
    .use(PatientContextMiddleware())     // Sets patient context
    .use(HIPAAComplianceMiddleware())    // Uses patient context
    .use(AuditMiddleware())              // Logs with full context

// Emergency alerts (priority-based)
let emergencyPipeline = PriorityPipeline()
// Critical: Life-threatening (90% resources)
// High: Urgent care (8% resources)  
// Normal: Routine (2% resources)
```

#### Financial Trading System
```swift
// Market data (concurrent processing)
let marketDataPipeline = ConcurrentPipeline(maxConcurrency: 8)
    .use(DataValidationMiddleware())
    .use(MarketAnalysisMiddleware())
    .use(DistributionMiddleware())

// Trade execution (secure + priority)
let tradePipeline = SecurePipelineBuilder()
    .add(PriorityMiddleware())           // Large orders first
    .add(RiskManagementMiddleware())
    .add(ComplianceMiddleware())
    .add(EncryptionMiddleware())
    .build()
```

### Middleware Stack

```swift
public enum MiddlewareOrder: Int, Sendable, CaseIterable {
    // Pre-Processing (0-99)
    case correlation = 10
    case requestId = 20
    case tracing = 30
    
    // Security (100-299)
    case authentication = 100
    case authorization = 200
    case validation = 300
    case sanitization = 310
    case rateLimiting = 320
    case encryption = 330
    
    // Traffic Control (400-499)
    case loadBalancing = 400
    case circuitBreaker = 410
    case timeout = 420
    case retry = 430
    
    // And 40+ more predefined orders...
}
```

### Core Components

```mermaid
graph TB
    A[Command] --> B[CommandBus]
    B --> C[Pipeline]
    C --> D[Middleware Chain]
    D --> E[CommandHandler]
    E --> F[Result]
    
    G[Security Middleware] --> D
    H[Audit Logger] --> D
    I[Rate Limiter] --> D
    J[Circuit Breaker] --> B
```

## 🔒 Security Features

### Input Validation

```swift
// Built-in validators
try Validator.notEmpty(value, field: "username")
try Validator.email(email)
try Validator.alphanumeric(username)
try Validator.length(password, min: 8, max: 128)
try Validator.regex(phoneNumber, pattern: #"^\+?[1-9]\d{1,14}$"#)

// Custom validators
try Validator.custom(value) { value in
    guard isValid(value) else {
        throw ValidationError.custom("Invalid value")
    }
}
```

### Data Sanitization

```swift
// HTML sanitization
let safe = Sanitizer.html(userInput)

// SQL injection prevention
let safe = Sanitizer.sql(userInput)

// Remove non-printable characters
let safe = Sanitizer.removeNonPrintable(userInput)

// Truncate to safe length
let safe = Sanitizer.truncate(userInput, maxLength: 1000)
```

### Rate Limiting Strategies

```swift
// Token bucket (burst tolerance)
let strategy = RateLimitStrategy.tokenBucket(capacity: 100, refillRate: 10)

// Sliding window (accurate)
let strategy = RateLimitStrategy.slidingWindow(windowSize: 60, maxRequests: 100)

// Adaptive (load-based)
let strategy = RateLimitStrategy.adaptive(baseRate: 100) {
    await getCurrentSystemLoad()
}
```

## 📊 Performance

PipelineKit is designed for high-performance scenarios:

- **Concurrent Execution**: Process multiple commands in parallel
- **Actor-Based Isolation**: Thread-safe without locks
- **Memory Efficient**: Minimal allocations with value types
- **Benchmarked**: Thoroughly tested for performance characteristics

### Benchmarks

```
Pipeline execution time: 0.006ms per command
Concurrent pipeline: 0.011ms per command
Memory usage: <1MB for 10,000 commands
```

## 🧪 Testing

Comprehensive test suite with 86 tests covering:

- ✅ Core functionality (Commands, Handlers, Pipelines)
- ✅ Security features (Validation, Authorization, Encryption)
- ✅ Concurrency and thread safety
- ✅ Performance characteristics
- ✅ Error handling and edge cases

Run tests:

```bash
swift test
```

## 📚 Documentation

- [Pipeline Types & Patterns](PIPELINES.md) - Comprehensive guide to choosing and configuring pipelines
- [Security Best Practices](SECURITY.md) - Essential security guidelines
- [Contributing Guidelines](CONTRIBUTING.md) - Development and contribution standards
- [API Documentation](https://docs.pipelinekit.dev) - Complete API reference
- [Examples](Examples/) - Real-world usage examples

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

### Development Setup

```bash
git clone https://github.com/yourorg/PipelineKit
cd PipelineKit
swift build
swift test
```

## 📄 License

PipelineKit is released under the MIT License. See [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- Built with Swift 6 and powered by structured concurrency
- Inspired by enterprise security patterns and best practices
- Designed for production-grade applications

---

**Security Notice**: This framework includes security features but requires proper implementation. Please review the [Security Best Practices](SECURITY.md) before production use.