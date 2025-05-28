# Pipeline Types and Patterns in PipelineKit

This guide provides in-depth coverage of PipelineKit's pipeline implementations, their internal mechanics, and best practices for choosing and configuring the right pipeline for your use case.

## 📋 Table of Contents

- [Pipeline Fundamentals](#pipeline-fundamentals)
- [Pipeline Types Deep Dive](#pipeline-types-deep-dive)
- [Performance Analysis](#performance-analysis)
- [Configuration Patterns](#configuration-patterns)
- [Migration Strategies](#migration-strategies)
- [Troubleshooting](#troubleshooting)

## 🎯 Pipeline Fundamentals

### Core Concepts

All pipelines in PipelineKit implement the same basic interface but differ in their execution strategies:

```swift
public protocol Pipeline: Sendable {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result
}
```

### Execution Models

1. **Sequential**: Middleware executes one after another
2. **Concurrent**: Independent middleware can run in parallel
3. **Priority-Based**: Commands are queued and processed by priority
4. **Context-Aware**: Middleware shares state through a context object
5. **Security-Ordered**: Middleware executes in security-compliant order

## 🔧 Pipeline Types Deep Dive

### 1. Standard Pipeline

**Internal Architecture:**
```
Command → [Middleware 1] → [Middleware 2] → [Middleware N] → Handler → Result
```

**Implementation Details:**
```swift
// Simplified internal structure
public final class DefaultPipeline: Pipeline {
    private var middleware: [any Middleware] = []
    
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        var index = 0
        
        func executeNext(_ cmd: T, _ meta: CommandMetadata) async throws -> T.Result {
            guard index < middleware.count else {
                fatalError("No handler registered for command type \(String(describing: T.self))")
            }
            
            let currentMiddleware = middleware[index]
            index += 1
            
            return try await currentMiddleware.execute(cmd, metadata: meta, next: executeNext)
        }
        
        return try await executeNext(command, metadata)
    }
}
```

**When to Use:**
- ✅ Simple applications with predictable load
- ✅ Development and testing environments
- ✅ Order-critical operations (financial transactions)
- ✅ Resource-constrained environments
- ❌ High-throughput applications
- ❌ I/O-heavy operations

**Example - Content Management System:**
```swift
struct PublishArticleCommand: Command {
    let title: String
    let content: String
    let authorId: String
    typealias Result = Article
}

let contentPipeline = DefaultPipeline()
contentPipeline.addMiddleware(ValidationMiddleware())     // Validate title, content
contentPipeline.addMiddleware(AuthorizationMiddleware())  // Check publish permissions
contentPipeline.addMiddleware(SanitizationMiddleware())   // Clean HTML content
contentPipeline.addMiddleware(SEOMiddleware())            // Add meta tags
contentPipeline.addMiddleware(CacheInvalidationMiddleware()) // Clear relevant caches

// Simple, predictable execution
let article = try await contentPipeline.execute(publishCommand, metadata: userMetadata)
```

---

### 2. Concurrent Pipeline

**Internal Architecture:**
```
Command → [Parallel Group 1] → [Parallel Group 2] → Handler → Result
          ├─ Middleware A    ├─ Middleware D
          ├─ Middleware B    └─ Middleware E
          └─ Middleware C
```

**Implementation Details:**
```swift
public final class ConcurrentPipeline: Pipeline {
    private let strategy: ConcurrencyStrategy
    private let semaphore: AsyncSemaphore?
    private var middleware: [any Middleware] = []
    
    public init(strategy: ConcurrencyStrategy = .unlimited) {
        self.strategy = strategy
        switch strategy {
        case .unlimited:
            self.semaphore = nil
        case .limited(let max):
            self.semaphore = AsyncSemaphore(value: max)
        }
    }
    
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        // Implementation uses TaskGroup for concurrent execution
        // with optional semaphore-based concurrency limiting
    }
}
```

**Dependency Analysis:**
The pipeline automatically analyzes middleware dependencies:

```swift
// Independent middleware (can run in parallel)
let validationGroup = [
    ValidationMiddleware(),    // No dependencies
    RateLimitingMiddleware(), // No dependencies  
    MetricsMiddleware()       // No dependencies
]

// Dependent middleware (must run after validation)
let processingGroup = [
    AuthorizationMiddleware(), // Needs validated input
    BusinessLogicMiddleware()  // Needs authorized context
]
```

**Performance Characteristics:**
```
Single-threaded: 100ms total (20ms + 30ms + 40ms + 10ms)
Concurrent:      50ms total  (max(20ms, 30ms, 40ms) + 10ms)
Speedup:         2x for this example
```

**When to Use:**
- ✅ I/O-bound operations (API calls, database queries)
- ✅ CPU-intensive tasks that can be parallelized
- ✅ High-throughput applications
- ✅ Independent validation/enrichment steps
- ❌ Order-critical operations
- ❌ Shared state between middleware

**Example - E-commerce Order Processing:**
```swift
struct ProcessOrderCommand: Command {
    let orderId: String
    let items: [OrderItem]
    typealias Result = OrderResult
}

let orderPipeline = ConcurrentPipeline(strategy: .limited(6))
// Independent validations (can run in parallel)
orderPipeline.addMiddleware(InventoryValidationMiddleware())  // Check stock levels
orderPipeline.addMiddleware(PaymentValidationMiddleware())    // Validate payment method
orderPipeline.addMiddleware(ShippingValidationMiddleware())   // Check shipping address
orderPipeline.addMiddleware(FraudDetectionMiddleware())       // Analyze for fraud

// Processing middleware
orderPipeline.addMiddleware(PaymentProcessingMiddleware())    // Charge payment
orderPipeline.addMiddleware(InventoryReservationMiddleware()) // Reserve items

// Fulfillment middleware
orderPipeline.addMiddleware(ShippingMiddleware())             // Create shipping label
orderPipeline.addMiddleware(NotificationMiddleware())         // Send confirmation

// Validation steps run concurrently, then processing, then fulfillment
let result = try await orderPipeline.execute(orderCommand, metadata: metadata)
```

---

### 3. Priority Pipeline

**Internal Architecture:**
```
Commands → Priority Queues → Weighted Scheduler → Pipeline → Results
           ├─ High (70%)
           ├─ Medium (20%)
           └─ Low (10%)
```

**Implementation Details:**
```swift
public final class PriorityPipeline: Pipeline {
    private var middleware: [any Middleware] = []
    private let priorityQueue: PriorityQueue<PrioritizedCommand>
    private let maxConcurrentTasks: Int
    
    func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        let priority = extractPriority(from: command, metadata: metadata)
        
        // Add to appropriate queue
        await queues[priority]?.queue.enqueue(command)
        
        // Scheduler processes based on weights
        return try await scheduler.process()
    }
    
    private func extractPriority<T: Command>(from command: T, metadata: CommandMetadata) -> Priority {
        // Check command-specific priority
        if let priorityCommand = command as? PriorityCommand {
            return priorityCommand.priority
        }
        
        // Check metadata
        if let priorityMetadata = metadata as? PriorityMetadata {
            return priorityMetadata.priority
        }
        
        // Check user level
        if let userMetadata = metadata as? UserMetadata {
            return userMetadata.user.priority
        }
        
        return .medium // Default
    }
}
```

**Scheduling Algorithm:**
```swift
// Weighted Fair Queuing (WFQ) implementation
class WeightedScheduler {
    func selectNextQueue() -> Priority? {
        let totalWeight = queues.values.reduce(0) { $0 + $1.weight }
        
        for (priority, queueInfo) in queues {
            let expectedShare = Double(queueInfo.weight) / Double(totalWeight)
            let actualShare = Double(queueInfo.processed) / Double(totalProcessed)
            
            // Priority queue that's under-served gets next slot
            if actualShare < expectedShare && !queueInfo.queue.isEmpty {
                return priority
            }
        }
        
        return nil
    }
}
```

**Priority Levels:**
```swift
public enum Priority: Int, CaseIterable {
    case emergency = 0    // System critical (5% of traffic)
    case high = 1        // VIP users, urgent (15% of traffic)
    case medium = 2      // Standard operations (60% of traffic)
    case low = 3         // Background tasks (20% of traffic)
}
```

**When to Use:**
- ✅ SLA-based processing (VIP customers)
- ✅ Emergency command handling
- ✅ Mixed workload environments
- ✅ Resource allocation fairness
- ❌ Simple applications with uniform priority
- ❌ Real-time systems requiring strict ordering

**Example - Customer Support System:**
```swift
struct SupportTicketCommand: Command, PriorityCommand {
    let ticketId: String
    let customerId: String
    let severity: TicketSeverity
    let description: String
    
    var priority: Priority {
        switch severity {
        case .critical: return .emergency    // System down
        case .high: return .high            // Major feature broken
        case .medium: return .medium        // Minor issue
        case .low: return .low              // Enhancement request
        }
    }
    
    typealias Result = TicketResult
}

let supportPipeline = PriorityPipeline(maxConcurrentTasks: 4)

// Add middleware for ticket processing
supportPipeline.addMiddleware(TicketValidationMiddleware())
supportPipeline.addMiddleware(CustomerVerificationMiddleware())
supportPipeline.addMiddleware(TicketRoutingMiddleware())
supportPipeline.addMiddleware(NotificationMiddleware())

// Emergency tickets get immediate attention based on priority
// Commands are automatically prioritized based on their ExecutionPriority
let result = try await supportPipeline.execute(ticketCommand, metadata: metadata)
```

---

### 4. Context-Aware Pipeline

**Internal Architecture:**
```
Command → Context → [Middleware 1 + Context] → [Middleware 2 + Context] → Handler → Result
                    ↓                         ↓
                    Context Updates          Context Reads
```

**Implementation Details:**
```swift
public final class ContextAwarePipeline: Pipeline {
    private var middleware: [any ContextAwareMiddleware] = []
    private var standardMiddleware: [any Middleware] = []
    
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result {
        let context = CommandContext()
        
        // Set initial context values from metadata
        if let contextMetadata = metadata as? ContextProvidingMetadata {
            await contextMetadata.populateContext(context)
        }
        
        // Execute context-aware middleware with shared context
        return try await executeWithContext(command, metadata: metadata, context: context)
    }
}

// Type-safe context storage
public actor CommandContext {
    private var storage: [ObjectIdentifier: Any] = [:]
    
    public func set<K: ContextKey>(_ keyType: K.Type, value: K.Value) {
        storage[ObjectIdentifier(keyType)] = value
    }
    
    public func get<K: ContextKey>(_ keyType: K.Type) -> K.Value? {
        return storage[ObjectIdentifier(keyType)] as? K.Value
    }
}
```

**Context Keys Pattern:**
```swift
// Define typed context keys
struct RequestIdKey: ContextKey {
    typealias Value = String
}

struct UserKey: ContextKey {
    typealias Value = User
}

struct MetricsKey: ContextKey {
    typealias Value = RequestMetrics
}

struct AuditTrailKey: ContextKey {
    typealias Value = [AuditEvent]
}
```

**Middleware Communication:**
```swift
struct RequestTrackingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Generate and store request ID
        let requestId = UUID().uuidString
        await context.set(RequestIdKey.self, value: requestId)
        
        // Start metrics collection
        let metrics = RequestMetrics(requestId: requestId, startTime: Date())
        await context.set(MetricsKey.self, value: metrics)
        
        let result = try await next(command, context)
        
        // Update metrics with completion time
        if var metrics = await context.get(MetricsKey.self) {
            metrics.endTime = Date()
            await context.set(MetricsKey.self, value: metrics)
        }
        
        return result
    }
}

struct AuditMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Use request ID from context
        let requestId = await context.get(RequestIdKey.self) ?? "unknown"
        let user = await context.get(UserKey.self)
        
        // Log command execution
        let auditEvent = AuditEvent(
            requestId: requestId,
            userId: user?.id,
            commandType: String(describing: T.self),
            timestamp: Date()
        )
        
        var auditTrail = await context.get(AuditTrailKey.self) ?? []
        auditTrail.append(auditEvent)
        await context.set(AuditTrailKey.self, value: auditTrail)
        
        return try await next(command, context)
    }
}
```

**When to Use:**
- ✅ Complex authentication/authorization flows
- ✅ Request correlation and tracing
- ✅ Comprehensive audit requirements
- ✅ Multi-step business processes
- ❌ Simple, stateless operations
- ❌ High-performance, low-latency scenarios

**Example - Multi-Factor Authentication:**
```swift
struct LoginCommand: Command {
    let username: String
    let password: String
    let mfaToken: String?
    typealias Result = AuthenticationResult
}

let authPipeline = ContextAwarePipeline()
authPipeline.addMiddleware(RequestTrackingMiddleware())      // Generate request ID
authPipeline.addMiddleware(RateLimitingMiddleware())         // Check login attempts
authPipeline.addMiddleware(PasswordValidationMiddleware())   // Validate credentials, store partial auth
authPipeline.addMiddleware(MFAValidationMiddleware())        // Check MFA using partial auth context
authPipeline.addMiddleware(SessionCreationMiddleware())      // Create session using full auth context
authPipeline.addMiddleware(AuditLoggingMiddleware())         // Log with full context including request ID

// Create metadata that provides initial context
struct AuthMetadata: CommandMetadata, ContextProvidingMetadata {
    let clientIP: String
    let userAgent: String
    
    func populateContext(_ context: CommandContext) async {
        await context.set(ClientIPKey.self, value: clientIP)
        await context.set(UserAgentKey.self, value: userAgent)
    }
}

let authResult = try await authPipeline.execute(loginCommand, metadata: AuthMetadata(
    clientIP: request.clientIP,
    userAgent: request.userAgent
))
```

---

### 5. Secure Pipeline (via Builder Pattern)

**Internal Architecture:**
```
Middleware → Security Ordering → Execution Pipeline → Security Monitoring
            ↓
            [Authentication: 100] → [Authorization: 200] → [Validation: 300] → [Business Logic]
```

**Implementation Details:**
```swift
public final class SecurePipelineBuilder {
    private var middleware: [PrioritizedMiddleware] = []
    private var pipelineType: PipelineType = .standard
    
    public func withPipeline(_ type: PipelineType) -> Self {
        self.pipelineType = type
        return self
    }
    
    public func add<T: Middleware>(
        _ middleware: T,
        order: MiddlewareOrder? = nil
    ) -> Self {
        let priority = order ?? determineDefaultOrder(for: middleware)
        self.middleware.append(PrioritizedMiddleware(
            middleware: middleware,
            order: priority
        ))
        return self
    }
    
    public func build() throws -> any Pipeline {
        // Sort by security order
        let sortedMiddleware = middleware
            .sorted { $0.order.rawValue < $1.order.rawValue }
            .map { $0.middleware }
        
        let pipeline = createPipeline(type: pipelineType)
        sortedMiddleware.forEach { pipeline.addMiddleware($0) }
        
        return pipeline
    }
}
```

**Security Ordering Enforcement:**
```swift
public enum MiddlewareOrder: Int, Sendable {
    // Pre-Processing (0-99)
    case correlation = 10
    case requestId = 20
    
    // Security (100-399)
    case authentication = 100      // Must come first
    case authorization = 200       // After authentication
    case validation = 300          // After authorization
    case sanitization = 310        // After validation
    case rateLimiting = 320        // Traffic control
    case encryption = 330          // Data protection
    
    // Business Logic (400-699)
    case businessRules = 400
    case dataAccess = 500
    
    // Post-Processing (700-999)
    case auditLogging = 800        // Near the end
    case responseFormatting = 900  // Last processing step
}
```

**Security Validation:**
```swift
extension SecurePipelineBuilder {
    func validateSecurityCompliance() throws {
        let orders = middlewareWithOrder.map { $0.order }
        
        // Ensure authentication comes before authorization
        if orders.contains(.authorization) && !orders.contains(.authentication) {
            throw SecurityValidationError.authorizationWithoutAuthentication
        }
        
        // Ensure validation comes before business logic
        if orders.contains(.businessRules) && !orders.contains(.validation) {
            throw SecurityValidationError.businessLogicWithoutValidation
        }
        
        // Ensure audit logging is present for sensitive operations
        if hasSensitiveMiddleware() && !orders.contains(.auditLogging) {
            throw SecurityValidationError.missingSensitiveAuditLogging
        }
    }
}
```

**When to Use:**
- ✅ Production applications
- ✅ Financial services
- ✅ Healthcare systems (HIPAA compliance)
- ✅ Government applications
- ✅ Any application handling sensitive data
- ❌ Internal tools without security requirements
- ❌ Prototype applications

**Example - Banking Transaction:**
```swift
struct TransferFundsCommand: Command {
    let fromAccount: String
    let toAccount: String
    let amount: Decimal
    let description: String
    typealias Result = TransactionResult
}

let bankingPipeline = try SecurePipelineBuilder()
    .withPipeline(.contextAware)  // Use context-aware for state sharing
    // Security middleware (order enforced automatically)
    .add(AuthenticationMiddleware())       // 100: Verify user identity
    .add(AuthorizationMiddleware())        // 200: Check transfer permissions
    .add(ValidationMiddleware())           // 300: Validate account numbers, amount
    .add(SanitizationMiddleware())         // 310: Clean description text
    .add(RateLimitingMiddleware())         // 320: Prevent rapid-fire transfers
    .add(EncryptionMiddleware())           // 330: Encrypt sensitive data
    
    // Business logic
    .add(FraudDetectionMiddleware())       // 400: Check for suspicious patterns
    .add(ComplianceMiddleware())           // 410: Regulatory compliance (AML/KYC)
    .add(AccountValidationMiddleware())    // 500: Verify accounts exist and are active
    .add(BalanceCheckMiddleware())         // 510: Ensure sufficient funds
    
    // Post-processing
    .add(AuditLoggingMiddleware())         // 800: Comprehensive audit trail
    .add(NotificationMiddleware())         // 900: Send confirmation
    
    .build()

// Executes in security-compliant order regardless of add() sequence
let result = try await bankingPipeline.execute(transferCommand, metadata: userMetadata)
```

## 📊 Performance Analysis

### Latency Comparison

```swift
// Benchmark results for 1000 commands with 5 middleware each

Pipeline Type       | Average Latency | P95 Latency | P99 Latency
--------------------|-----------------|-------------|------------
Basic              | 12ms           | 18ms        | 25ms
Concurrent         | 8ms            | 12ms        | 18ms
Priority           | 15ms           | 22ms        | 35ms
Context-Aware      | 14ms           | 20ms        | 28ms
Secure             | 16ms           | 24ms        | 32ms
```

### Throughput Comparison

```swift
// Commands per second at 95% CPU utilization

Pipeline Type       | Throughput (cmd/sec)
--------------------|--------------------
Basic              | 2,100
Concurrent         | 4,800
Priority           | 1,850
Context-Aware      | 1,950
Secure             | 1,700
```

### Memory Usage

```swift
// Memory overhead per command execution

Pipeline Type       | Base Memory | Per Command | Context Size
--------------------|-------------|-------------|-------------
Basic              | 2MB         | 1.2KB       | N/A
Concurrent         | 4MB         | 2.1KB       | N/A
Priority           | 6MB         | 1.8KB       | N/A
Context-Aware      | 3MB         | 3.5KB       | 2KB
Secure             | 5MB         | 2.8KB       | N/A
```

## 🔍 Observability and Monitoring

### Pipeline Observability

All pipeline types support comprehensive observability through the PipelineObserver protocol:

```swift
// Create custom observer
class MetricsObserver: PipelineObserver {
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        metrics.increment("pipeline.start", tags: ["type": pipelineType, "command": String(describing: T.self)])
    }
    
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        metrics.histogram("pipeline.duration", value: duration, tags: ["type": pipelineType, "command": String(describing: T.self)])
        metrics.increment("pipeline.success", tags: ["type": pipelineType, "command": String(describing: T.self)])
    }
}

// Attach to any pipeline
let observablePipeline = pipeline.withObservability(observers: [
    MetricsObserver(),
    OSLogObserver.production(),
    DatadogObserver(apiKey: "...")
])
```

### Built-in Observability Features

#### 1. OSLog Integration
```swift
// Automatic structured logging with privacy protection
let osLogObserver = OSLogObserver(configuration: .init(
    subsystem: "com.myapp.pipeline",
    logLevel: .info,
    includeCommandDetails: true,
    includeMetadata: true,
    performanceThreshold: 0.5 // Log slow commands
))
```

#### 2. Performance Tracking
```swift
// Automatic performance monitoring
let performanceObserver = PerformanceTrackingMiddleware(
    thresholds: .init(
        slowCommandThreshold: 1.0,
        slowMiddlewareThreshold: 0.1,
        memoryUsageThreshold: 50
    )
)

// Alerts when thresholds are exceeded
pipeline.addMiddleware(performanceObserver)
```

#### 3. Distributed Tracing
```swift
// Trace requests across services
struct TracingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        let span = await context.getOrCreateSpanContext(operation: String(describing: T.self))
        
        // Propagate trace headers
        if let httpClient = await context.get(HTTPClientKey.self) {
            httpClient.headers["X-Trace-ID"] = span.traceId
            httpClient.headers["X-Span-ID"] = span.spanId
        }
        
        return try await next(command, context)
    }
}
```

#### 4. Observability Middleware
```swift
// One-line comprehensive observability
try await pipeline.addMiddleware(
    ObservabilityMiddleware(configuration: .init(
        observers: [OSLogObserver.development()],
        enablePerformanceMetrics: true
    ))
)
```

### Monitoring Dashboard Example

```swift
// Real-time pipeline monitoring
actor PipelineMonitor {
    private var metrics: PipelineMetrics = .init()
    
    func trackExecution<T: Command>(_ command: T, duration: TimeInterval, success: Bool) {
        metrics.totalCommands += 1
        metrics.totalDuration += duration
        
        if success {
            metrics.successCount += 1
        } else {
            metrics.failureCount += 1
        }
        
        // Update moving averages
        metrics.averageLatency = metrics.totalDuration / Double(metrics.totalCommands)
        metrics.successRate = Double(metrics.successCount) / Double(metrics.totalCommands)
    }
    
    func getMetrics() -> PipelineMetrics {
        return metrics
    }
}

struct PipelineMetrics {
    var totalCommands: Int = 0
    var successCount: Int = 0
    var failureCount: Int = 0
    var totalDuration: TimeInterval = 0
    var averageLatency: TimeInterval = 0
    var successRate: Double = 0
}
```

### Custom Event Emission

```swift
// Emit business-specific events
struct PaymentProcessingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        if let paymentCommand = command as? ProcessPaymentCommand {
            await context.emitCustomEvent("payment.started", properties: [
                "amount": paymentCommand.amount,
                "currency": paymentCommand.currency,
                "method": paymentCommand.method
            ])
        }
        
        do {
            let result = try await next(command, context)
            
            if let paymentCommand = command as? ProcessPaymentCommand {
                await context.emitCustomEvent("payment.completed", properties: [
                    "transaction_id": result.transactionId,
                    "amount": paymentCommand.amount
                ])
            }
            
            return result
        } catch {
            await context.emitCustomEvent("payment.failed", properties: [
                "error": error.localizedDescription
            ])
            throw error
        }
    }
}
```

## ⚙️ Configuration Patterns

### Development Environment

```swift
// Fast, minimal security for development
let devPipeline = DefaultPipeline()
devPipeline.addMiddleware(ValidationMiddleware(strictMode: false))
devPipeline.addMiddleware(MockAuthenticationMiddleware())  // Always succeeds
devPipeline.addMiddleware(LoggingMiddleware(level: .debug))
```

### Testing Environment

```swift
// Comprehensive testing with mocked external dependencies
let testPipeline = ConcurrentPipeline(strategy: .unlimited)
testPipeline.addMiddleware(ValidationMiddleware(strictMode: true))
testPipeline.addMiddleware(MockRateLimitingMiddleware())   // Predictable behavior
testPipeline.addMiddleware(InMemoryAuditMiddleware())      // Fast logging
```

### Staging Environment

```swift
// Production-like with relaxed limits
let stagingPipeline = SecurePipelineBuilder()
    .add(ValidationMiddleware())
    .add(AuthenticationMiddleware())
    .add(AuthorizationMiddleware())
    .add(RateLimitingMiddleware(
        limiter: RateLimiter(
            strategy: .tokenBucket(capacity: 10000, refillRate: 1000)
        )
    ))
    .add(AuditLoggingMiddleware(privacyLevel: .full))
    .build()
```

### Production Environment

```swift
// Maximum security and monitoring
let productionPipeline = try SecurePipelineBuilder()
    .withPipeline(.concurrent(.limited(10)))  // Limited concurrency for control
    .add(ValidationMiddleware())
    .add(AuthenticationMiddleware())
    .add(AuthorizationMiddleware())
    .add(RateLimitingMiddleware(
        limiter: RateLimiter(
            strategy: .slidingWindow(windowSize: 60, limit: 1000)
        )
    ))
    .add(EncryptionMiddleware())
    .add(AuditLoggingMiddleware(privacyLevel: .masked))
    .build()
```

## 🔄 Migration Strategies

### From Basic to Concurrent

```swift
// Step 1: Identify independent middleware
let independentMiddleware = [
    ValidationMiddleware(),
    MetricsMiddleware(),
    CacheMiddleware()
]

let dependentMiddleware = [
    AuthorizationMiddleware(),  // Depends on validation
    BusinessLogicMiddleware()   // Depends on authorization
]

// Step 2: Gradual migration
let hybridPipeline = ConcurrentPipeline()
    // Group 1: Independent (parallel)
    .use(independentMiddleware)
    // Group 2: Dependent (sequential)
    .use(dependentMiddleware)
```

### From Basic to Priority

```swift
// Step 1: Add priority metadata
extension DefaultCommandMetadata {
    var priority: Priority {
        // Extract from user tier, command type, etc.
        return userTier == .premium ? .high : .medium
    }
}

// Step 2: Migrate gradually
let priorityPipeline = PriorityPipeline()
priorityPipeline.addQueue(priority: .high, weight: 60)
priorityPipeline.addQueue(priority: .medium, weight: 30)
priorityPipeline.addQueue(priority: .low, weight: 10)
```

### Adding Security (Basic → Secure)

```swift
// Step 1: Add security middleware incrementally
let basicPipeline = DefaultPipeline()
basicPipeline.addMiddleware(ValidationMiddleware())        // Existing
basicPipeline.addMiddleware(AuthenticationMiddleware())    // Add first
basicPipeline.addMiddleware(YourBusinessMiddleware())      // Existing

// Step 2: Add authorization
let enhancedPipeline = DefaultPipeline()
enhancedPipeline.addMiddleware(AuthenticationMiddleware())
enhancedPipeline.addMiddleware(AuthorizationMiddleware())     // Add second
enhancedPipeline.addMiddleware(ValidationMiddleware())
enhancedPipeline.addMiddleware(YourBusinessMiddleware())

// Step 3: Convert to SecurePipelineBuilder
let securePipeline = try SecurePipelineBuilder()
    .add(AuthenticationMiddleware())
    .add(AuthorizationMiddleware())
    .add(ValidationMiddleware())
    .add(YourBusinessMiddleware())
    .build()  // Automatically orders correctly
```

## 🔍 Troubleshooting

### Common Issues

#### 1. Concurrent Pipeline Race Conditions

**Problem:** Middleware modifying shared state causes inconsistent results.

**Solution:**
```swift
// ❌ BAD: Shared mutable state
class CounterMiddleware: Middleware {
    private var count = 0  // Race condition!
    
    func execute<T: Command>(...) async throws -> T.Result {
        count += 1  // Not thread-safe
        return try await next(command, metadata)
    }
}

// ✅ GOOD: Actor-based state
actor ThreadSafeCounter {
    private var count = 0
    
    func increment() { count += 1 }
    func getCount() -> Int { count }
}

class CounterMiddleware: Middleware {
    private let counter = ThreadSafeCounter()
    
    func execute<T: Command>(...) async throws -> T.Result {
        await counter.increment()  // Thread-safe
        return try await next(command, metadata)
    }
}
```

#### 2. Priority Pipeline Starvation

**Problem:** Low-priority commands never execute.

**Solution:**
```swift
// ❌ BAD: Weights that can cause starvation
priorityPipeline.addQueue(priority: .high, weight: 95)
priorityPipeline.addQueue(priority: .low, weight: 5)

// ✅ GOOD: Guaranteed minimum allocation
priorityPipeline.addQueue(priority: .high, weight: 70)
priorityPipeline.addQueue(priority: .medium, weight: 20)
priorityPipeline.addQueue(priority: .low, weight: 10)  // Always gets 10%
```

#### 3. Context-Aware Memory Leaks

**Problem:** Context accumulates data without cleanup.

**Solution:**
```swift
// ✅ GOOD: Context lifecycle management
struct ContextCleanupMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        defer {
            // Clean up after execution
            Task {
                await context.cleanup(olderThan: Date().addingTimeInterval(-300))
            }
        }
        
        return try await next(command, context)
    }
}
```

#### 4. Secure Pipeline Performance

**Problem:** Security middleware adds too much latency.

**Solution:**
```swift
// Profile and optimize critical paths
let optimizedPipeline = SecurePipelineBuilder()
    .add(FastValidationMiddleware())      // Optimize validation rules
    .add(CachedAuthenticationMiddleware()) // Cache auth results
    .add(AuthorizationMiddleware())
    .add(AsyncAuditMiddleware())          // Don't block on audit writes
    .build()
```

### Performance Monitoring

```swift
class PipelineMonitor {
    func monitorPipeline<T: Pipeline>(_ pipeline: T) {
        Task {
            while !Task.isCancelled {
                // Monitor execution through metrics middleware
                // MetricsMiddleware automatically tracks:
                // - Request count
                // - Success/failure rates
                // - Execution time
                // - Concurrent executions
                
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
        }
    }
}
```

---

This comprehensive guide should help you choose the right pipeline type for your specific use case and configure it optimally for your requirements.
