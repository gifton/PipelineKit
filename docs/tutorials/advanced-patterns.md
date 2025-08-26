# Advanced Patterns

This guide covers advanced patterns and techniques for building sophisticated pipelines with PipelineKit.

## Conditional Middleware Execution

Execute middleware based on runtime conditions:

```swift
// Conditional wrapper
struct ConditionalMiddleware<M: Middleware>: Middleware {
    let wrapped: M
    let condition: @Sendable (Any, CommandContext) async -> Bool
    
    var priority: ExecutionPriority { wrapped.priority }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if await condition(command, context) {
            return try await wrapped.execute(command, context: context, next: next)
        } else {
            return try await next(command, context)
        }
    }
}

// Usage
let debugLogging = ConditionalMiddleware(
    wrapped: VerboseLoggingMiddleware(),
    condition: { _, context in
        // Only log in debug mode
        context.get(DebugModeKey.self) ?? false
    }
)
```

## Dynamic Pipeline Configuration

Build pipelines based on runtime configuration:

```swift
struct PipelineFactory {
    enum Environment {
        case development
        case staging
        case production
    }
    
    static func build<H: CommandHandler>(
        handler: H,
        environment: Environment
    ) async throws -> any Pipeline {
        let builder = PipelineBuilder(handler: handler)
        
        // Common middleware
        builder.with(RequestIDMiddleware())
               .with(AuthenticationMiddleware())
        
        // Environment-specific middleware
        switch environment {
        case .development:
            builder.with(VerboseLoggingMiddleware())
                   .with(DebugMiddleware())
        
        case .staging:
            builder.with(StandardLoggingMiddleware())
                   .with(PerformanceMiddleware())
        
        case .production:
            builder.with(ProductionLoggingMiddleware())
                   .with(CachedAuthorizationMiddleware())
                   .with(RateLimitingMiddleware())
                   .with(MetricsMiddleware())
        }
        
        // Optimization only in production
        return environment == .production 
            ? try await builder.build()
            : try await builder.build()
    }
}
```

## Middleware Composition

Compose multiple middleware into reusable units:

```swift
// Composite middleware
struct SecurityMiddleware: Middleware {
    let priority = ExecutionPriority.authentication
    
    private let authMiddleware = AuthenticationMiddleware()
    private let authzMiddleware = AuthorizationMiddleware()
    private let auditMiddleware = SecurityAuditMiddleware()
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Create a chain of security middleware
        let securityChain: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            try await self.authMiddleware.execute(cmd, context: ctx) { c, ctx2 in
                try await self.authzMiddleware.execute(c, context: ctx2) { c2, ctx3 in
                    try await self.auditMiddleware.execute(c2, context: ctx3, next: next)
                }
            }
        }
        
        return try await securityChain(command, context)
    }
}

// Or use a builder extension
extension PipelineBuilder {
    func withSecurity() -> Self {
        self.with(AuthenticationMiddleware())
            .with(AuthorizationMiddleware())
            .with(SecurityAuditMiddleware())
    }
}
```

## Event Sourcing Pattern

Capture all commands as events:

```swift
// Event protocol
protocol Event: Codable, Sendable {
    var id: String { get }
    var timestamp: Date { get }
    var commandType: String { get }
    var userId: String? { get }
}

// Event store protocol
protocol EventStore: Sendable {
    func append(_ event: Event) async throws
    func events(since: Date?) async throws -> [Event]
}

// Event sourcing middleware
struct EventSourcingMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    let eventStore: EventStore
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Create event
        let event = CommandEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            commandType: String(describing: type(of: command)),
            userId: context.commandMetadata.userId,
            commandData: try JSONEncoder().encode(command)
        )
        
        // Store event before execution
        try await eventStore.append(event)
        
        // Execute command
        do {
            let result = try await next(command, context)
            
            // Store success event
            let successEvent = CommandSuccessEvent(
                commandId: event.id,
                timestamp: Date()
            )
            try await eventStore.append(successEvent)
            
            return result
        } catch {
            // Store failure event
            let failureEvent = CommandFailureEvent(
                commandId: event.id,
                timestamp: Date(),
                error: String(describing: error)
            )
            try await eventStore.append(failureEvent)
            
            throw error
        }
    }
}
```

## Circuit Breaker Pattern

Protect against cascading failures:

```swift
// Circuit breaker implementation
actor CircuitBreaker {
    enum State {
        case closed
        case open(until: Date)
        case halfOpen
    }
    
    private var state: State = .closed
    private var failureCount = 0
    private let failureThreshold: Int
    private let resetTimeout: TimeInterval
    
    init(failureThreshold: Int = 5, resetTimeout: TimeInterval = 60) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }
    
    func canExecute() -> Bool {
        switch state {
        case .closed, .halfOpen:
            return true
        case .open(let until):
            if Date() > until {
                state = .halfOpen
                return true
            }
            return false
        }
    }
    
    func recordSuccess() {
        failureCount = 0
        state = .closed
    }
    
    func recordFailure() {
        failureCount += 1
        
        if failureCount >= failureThreshold {
            state = .open(until: Date().addingTimeInterval(resetTimeout))
        }
    }
}

// Circuit breaker middleware
struct CircuitBreakerMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    let circuitBreaker: CircuitBreaker
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        guard await circuitBreaker.canExecute() else {
            throw CircuitBreakerError.open
        }
        
        do {
            let result = try await next(command, context)
            await circuitBreaker.recordSuccess()
            return result
        } catch {
            await circuitBreaker.recordFailure()
            throw error
        }
    }
}

enum CircuitBreakerError: Error {
    case open
}
```

## Saga Pattern

Manage distributed transactions:

```swift
// Saga step protocol
protocol SagaStep {
    associatedtype StepCommand: Command
    associatedtype CompensationCommand: Command
    
    func execute(_ command: StepCommand) async throws -> StepCommand.Result
    func compensate(_ command: CompensationCommand) async throws
}

// Saga coordinator
class SagaCoordinator<H: CommandHandler> {
    private let pipeline: any Pipeline
    private var executedSteps: [(any SagaStep, Any)] = []
    
    init(pipeline: any Pipeline) {
        self.pipeline = pipeline
    }
    
    func execute<S: SagaStep>(
        step: S,
        command: S.StepCommand
    ) async throws -> S.StepCommand.Result {
        do {
            let result = try await step.execute(command)
            executedSteps.append((step, command))
            return result
        } catch {
            // Compensate in reverse order
            await compensateAll()
            throw error
        }
    }
    
    private func compensateAll() async {
        for (step, command) in executedSteps.reversed() {
            do {
                // Create compensation command based on original
                // This is simplified - real implementation would be more complex
                print("Compensating step: \(type(of: step))")
            } catch {
                print("Compensation failed: \(error)")
            }
        }
    }
}

// Example saga
struct OrderSaga {
    let paymentStep: PaymentStep
    let inventoryStep: InventoryStep
    let shippingStep: ShippingStep
    
    func execute(order: Order) async throws {
        let coordinator = SagaCoordinator(pipeline: pipeline)
        
        // Execute saga steps
        let payment = try await coordinator.execute(
            step: paymentStep,
            command: ChargePaymentCommand(order: order)
        )
        
        let inventory = try await coordinator.execute(
            step: inventoryStep,
            command: ReserveInventoryCommand(order: order)
        )
        
        let shipping = try await coordinator.execute(
            step: shippingStep,
            command: CreateShippingCommand(order: order, payment: payment)
        )
    }
}
```

## Performance Monitoring

Advanced performance tracking:

```swift
// Performance metrics
struct PerformanceMetrics {
    let commandType: String
    let executionTime: TimeInterval
    let middlewareTimings: [String: TimeInterval]
    let contextSize: Int
    let memoryUsage: Int
}

// Advanced performance middleware
class AdvancedPerformanceMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    private let metricsCollector: MetricsCollector
    
    init(metricsCollector: MetricsCollector) {
        self.metricsCollector = metricsCollector
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = CFAbsoluteTimeGetCurrent()
        let startMemory = getCurrentMemoryUsage()
        
        // Track middleware execution times
        context.set(startTime, for: PerformanceStartKey.self)
        
        do {
            let result = try await next(command, context)
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let endMemory = getCurrentMemoryUsage()
            
            // Collect middleware timings
            let timings = context.get(MiddlewareTimingsKey.self) ?? [:]
            
            let metrics = PerformanceMetrics(
                commandType: String(describing: type(of: command)),
                executionTime: endTime - startTime,
                middlewareTimings: timings,
                contextSize: context.estimatedSize,
                memoryUsage: endMemory - startMemory
            )
            
            await metricsCollector.record(metrics)
            
            // Alert on slow operations
            if metrics.executionTime > 1.0 {
                print("  Slow operation detected: \(metrics.commandType) took \(metrics.executionTime)s")
            }
            
            return result
        } catch {
            await metricsCollector.recordError(
                commandType: String(describing: type(of: command)),
                error: error
            )
            throw error
        }
    }
    
    private func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
```

## Distributed Tracing

Integrate with distributed tracing systems:

```swift
// Tracing context
struct TracingContext {
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let baggage: [String: String]
}

// Tracing middleware
struct DistributedTracingMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    let tracer: DistributedTracer
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Extract or create trace context
        let traceContext = context.get(TracingContextKey.self) ?? TracingContext(
            traceId: UUID().uuidString,
            spanId: UUID().uuidString,
            parentSpanId: nil,
            baggage: [:]
        )
        
        // Start span
        let span = tracer.startSpan(
            name: "command.\(type(of: command))",
            traceId: traceContext.traceId,
            parentSpanId: traceContext.spanId
        )
        
        // Add attributes
        span.setAttribute("command.type", String(describing: type(of: command)))
        span.setAttribute("user.id", context.commandMetadata.userId ?? "anonymous")
        
        // Propagate trace context
        let newTraceContext = TracingContext(
            traceId: traceContext.traceId,
            spanId: span.spanId,
            parentSpanId: traceContext.spanId,
            baggage: traceContext.baggage
        )
        context.set(newTraceContext, for: TracingContextKey.self)
        
        do {
            let result = try await next(command, context)
            span.setStatus(.ok)
            span.end()
            return result
        } catch {
            span.setStatus(.error(String(describing: error)))
            span.end()
            throw error
        }
    }
}
```

## Middleware Testing Patterns

Advanced testing strategies:

```swift
// Test doubles
struct SpyMiddleware: Middleware {
    let priority: ExecutionPriority
    private let onExecute: @Sendable (Any, CommandContext) async -> Void
    
    init(
        priority: ExecutionPriority = .processing,
        onExecute: @escaping @Sendable (Any, CommandContext) async -> Void
    ) {
        self.priority = priority
        self.onExecute = onExecute
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        await onExecute(command, context)
        return try await next(command, context)
    }
}

// Test harness
class MiddlewareTestHarness<M: Middleware> {
    let middleware: M
    var executionCount = 0
    var lastCommand: (any Command)?
    var lastContext: CommandContext?
    var thrownError: Error?
    
    init(middleware: M) {
        self.middleware = middleware
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext = CommandContext(metadata: StandardCommandMetadata()),
        returning result: T.Result
    ) async throws -> T.Result {
        executionCount += 1
        lastCommand = command
        lastContext = context
        
        return try await middleware.execute(command, context: context) { _, _ in
            result
        }
    }
}

// Usage in tests
func testCachingMiddleware() async throws {
    let cache = InMemoryMiddlewareCache()
    let middleware = CachedMiddleware(
        wrapping: ExpensiveMiddleware(),
        cache: cache,
        ttl: 60
    )
    
    let harness = MiddlewareTestHarness(middleware: middleware)
    
    // First call - cache miss
    let result1 = try await harness.execute(
        TestCommand(id: "1"),
        returning: "expensive result"
    )
    
    // Second call - cache hit
    let result2 = try await harness.execute(
        TestCommand(id: "1"),
        returning: "different result" // Won't be used
    )
    
    XCTAssertEqual(result1, result2) // Cached
    XCTAssertEqual(harness.executionCount, 2)
}
```

## Conclusion

These advanced patterns demonstrate PipelineKit's flexibility and power. Key takeaways:

1. **Composition**: Build complex behaviors from simple middleware
2. **Separation of Concerns**: Keep business logic separate from cross-cutting concerns
3. **Testability**: Design with testing in mind
4. **Performance**: Use caching and optimization where appropriate
5. **Resilience**: Implement patterns like circuit breakers for fault tolerance

For more examples, see [Custom Middleware](custom-middleware.md) development.