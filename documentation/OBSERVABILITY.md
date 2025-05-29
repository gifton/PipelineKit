# Observability in PipelineKit

This guide covers PipelineKit's comprehensive observability features, enabling you to monitor, debug, and optimize your command execution pipeline.

## 📋 Table of Contents

- [Overview](#overview)
- [Core Concepts](#core-concepts)
- [Pipeline Observer Protocol](#pipeline-observer-protocol)
- [Built-in Observers](#built-in-observers)
- [Observability Middleware](#observability-middleware)
- [Context Extensions](#context-extensions)
- [Distributed Tracing](#distributed-tracing)
- [Performance Monitoring](#performance-monitoring)
- [Custom Metrics](#custom-metrics)
- [Security Observability](#security-observability)
- [Best Practices](#best-practices)
- [Integration Examples](#integration-examples)

## 🎯 Overview

PipelineKit's observability system provides:

- **Real-time Monitoring**: Track command execution as it happens
- **Performance Insights**: Identify bottlenecks and optimize performance
- **Security Tracking**: Monitor security events and threats
- **Distributed Tracing**: Follow requests across service boundaries
- **Custom Metrics**: Emit business-specific events and metrics
- **Structured Logging**: Comprehensive logs with privacy protection

## 🔍 Core Concepts

### Observer Pattern

PipelineKit uses the observer pattern to decouple monitoring from execution:

```swift
// Observers receive events without affecting pipeline execution
pipeline.withObservability(observers: [
    MetricsObserver(),      // Send to metrics system
    LoggingObserver(),      // Structured logging
    TracingObserver()       // Distributed tracing
])
```

### Event Lifecycle

Every command execution emits these events:

1. `pipelineWillExecute` - Command execution starting
2. `middlewareWillExecute` - Each middleware starting
3. `middlewareDidExecute` - Each middleware completed
4. `handlerWillExecute` - Handler starting
5. `handlerDidExecute` - Handler completed
6. `pipelineDidExecute` - Command execution completed

## 📡 Pipeline Observer Protocol

Implement custom observers by conforming to `PipelineObserver`:

```swift
public protocol PipelineObserver: Sendable {
    // Pipeline lifecycle
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async
    
    // Middleware lifecycle
    func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async
    func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async
    func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async
    
    // Handler lifecycle
    func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async
    func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async
    func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async
    
    // Custom events
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async
}
```

### Custom Observer Example

```swift
class DatadogObserver: PipelineObserver {
    private let client: DatadogClient
    
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await client.gauge("pipeline.duration", value: duration, tags: [
            "command": String(describing: T.self),
            "pipeline": pipelineType,
            "success": "true"
        ])
        
        await client.increment("pipeline.requests", tags: [
            "command": String(describing: T.self),
            "pipeline": pipelineType
        ])
    }
    
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        await client.event(eventName, properties: properties, tags: [
            "correlation_id": correlationId
        ])
    }
}
```

## 🛠️ Built-in Observers

PipelineKit provides several pre-built observers for common observability needs:

### ConsoleObserver

Simple, configurable console logging for development and debugging:

```swift
// Pre-configured for common scenarios
let devObserver = ConsoleObserver.development()    // Pretty format, verbose
let prodObserver = ConsoleObserver.production()    // Simple format, warnings only
let debugObserver = ConsoleObserver.debugging()    // Detailed format, all events

// Custom configuration
let customObserver = ConsoleObserver(
    style: .pretty,              // .simple, .detailed, .pretty
    level: .info,               // .verbose, .info, .warning, .error
    includeTimestamps: true
)
```

Output styles:
- **Simple**: `[10:30:45.123] Pipeline completed: CreateUserCommand in 45ms`
- **Pretty**: 
  ```
  [10:30:45.123] ✅ Pipeline Completed
  ├─ Command: CreateUserCommand
  ├─ Duration: 45ms
  └─ ID: abc-123
  ```

### MemoryObserver

Stores events in memory for testing, debugging, and analysis:

```swift
// Configure memory observer
let memoryObserver = MemoryObserver(options: .init(
    maxEvents: 10000,                    // Circular buffer size
    captureMiddlewareEvents: true,       // Track middleware execution
    captureHandlerEvents: true,          // Track handler execution
    cleanupInterval: 3600                // Auto-cleanup after 1 hour
))

// Start automatic cleanup
await memoryObserver.startCleanup()

// Query captured events
let allEvents = await memoryObserver.allEvents()
let errorEvents = await memoryObserver.errorEvents()
let pipelineEvents = await memoryObserver.pipelineEvents()
let eventsForRequest = await memoryObserver.events(for: correlationId)

// Get statistics
let stats = await memoryObserver.statistics()
print("Success rate: \(stats.successfulExecutions / stats.pipelineExecutions)")
print("Average duration: \(stats.averageDuration)s")
print("Top commands: \(stats.commandCounts)")

// Wait for specific conditions (useful in tests)
let completed = try await memoryObserver.waitForPipelineCompletions(5, timeout: 10.0)
```

### MetricsObserver

Integrates with metrics collection systems:

```swift
// Create with your metrics backend
let metricsObserver = MetricsObserver(
    backend: DatadogBackend(),  // Implement MetricsBackend protocol
    configuration: .init(
        metricPrefix: "myapp.pipeline",
        includeCommandType: true,
        includePipelineType: true,
        trackMiddleware: false,      // Reduce metric cardinality
        trackHandlers: false,
        globalTags: [
            "environment": "production",
            "service": "api",
            "version": "1.2.0"
        ]
    )
)

// Built-in backends for development
let consoleBackend = ConsoleMetricsBackend()     // Logs metrics to console
let inMemoryBackend = InMemoryMetricsBackend()   // Stores metrics in memory

// Example console output:
// [10:30:45.123] METRIC counter pipeline.started command=CreateUser +1
// [10:30:45.456] METRIC histogram pipeline.duration_ms command=CreateUser = 333
// [10:30:45.457] METRIC gauge pipeline.active = 5
```

### CompositeObserver

Combines multiple observers with error isolation:

```swift
// Combine observers for comprehensive monitoring
let compositeObserver = CompositeObserver(
    ConsoleObserver.production(),
    MetricsObserver(backend: prometheusBackend),
    OSLogObserver.production(),
    errorHandler: { error, observerType in
        // One observer's failure doesn't affect others
        logger.error("Observer \(observerType) failed: \(error)")
    }
)

// Or use variadic initializer
let observer = CompositeObserver(
    console,
    metrics,
    logging
)
```

### ConditionalObserver

Filters events based on conditions:

```swift
// Only observe specific command types
let paymentObserver = ConditionalObserver.forCommands(
    "PaymentCommand", "RefundCommand", "ChargebackCommand",
    observer: detailedAuditLogger
)

// Only observe failures
let errorObserver = ConditionalObserver.onlyFailures(
    observer: alertingService
)

// Pattern matching
let criticalObserver = ConditionalObserver.matching(
    pattern: "Critical",
    observer: pagerDutyObserver
)

// Custom conditions
let vipObserver = ConditionalObserver(
    wrapping: enhancedLogger,
    when: { commandType, correlationId in
        // Complex logic for VIP detection
        return correlationId?.hasPrefix("vip-") ?? false
            || commandType.contains("Premium")
            || isVIPUser(correlationId)
    }
)
```

### OSLogObserver

Integrates with Apple's unified logging system:

```swift
// Development configuration with detailed logging
let devObserver = OSLogObserver(configuration: .init(
    subsystem: "com.myapp.pipeline",
    logLevel: .debug,
    includeCommandDetails: true,
    includeMetadata: true,
    performanceThreshold: 0.5
))

// Pre-configured for common scenarios
let prodObserver = OSLogObserver.production()      // Privacy-safe, info level
let perfObserver = OSLogObserver.performance()     // Performance monitoring focus

// Structured log output with privacy markers
logger.info("""
🚀 Pipeline execution started
📋 Command: \(commandType, privacy: .public)
🔧 Pipeline: \(pipelineType, privacy: .public)
🔗 Correlation: \(correlationId, privacy: .public)
👤 User: \(userId, privacy: .private)
""")
```

### BaseObserver

Abstract base class for creating custom observers:

```swift
class CustomObserver: BaseObserver {
    // Only implement the methods you need
    override func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await recordMetric(command: T.self, duration: duration)
    }
    
    override func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await alertOnFailure(command: T.self, error: error)
    }
}
```

### ObserverRegistry

Thread-safe registry for managing multiple observers:

```swift
// Create registry with error handling
let registry = ObserverRegistry(
    observers: [console, metrics, logging],
    errorHandler: { failure in
        // Detailed error information
        logger.error("""
        Observer failed:
        - Type: \(failure.observerType)
        - Event: \(failure.eventName)
        - Error: \(failure.error)
        - Context: \(failure.additionalContext ?? "none")
        """)
    }
)

// Add/remove observers dynamically
await registry.addObserver(newObserver)
await registry.removeObserver(ofType: OldObserver.self)

// Use with ObservablePipeline
let pipeline = ObservablePipeline(
    wrapping: DefaultPipeline(handler: handler),
    observers: await registry.observers
)
```

## 🔌 Observability Middleware

Automatic instrumentation for all commands:

```swift
let pipeline = ContextAwarePipeline(handler: handler)

// Add comprehensive observability
try await pipeline.addMiddleware(
    ObservabilityMiddleware(configuration: .init(
        observers: [
            OSLogObserver.development(),
            MetricsObserver(),
            TracingObserver()
        ],
        enablePerformanceMetrics: true
    ))
)
```

### Configuration Options

```swift
public struct ObservabilityConfiguration {
    let observers: [PipelineObserver]
    let enableMiddlewareObservability: Bool
    let enableHandlerObservability: Bool
    let enablePerformanceMetrics: Bool
    let enableDistributedTracing: Bool
    
    // Predefined configurations
    static func development() -> Self
    static func production() -> Self
    static func minimal() -> Self
}
```

## 🔗 Context Extensions

### Span Context Management

```swift
// Create or get existing span
let span = await context.getOrCreateSpanContext(operation: "process_order")

// Create child span
let childSpan = await context.createChildSpan(
    operation: "validate_payment",
    tags: ["payment_method": "credit_card"]
)

// Access span information
print("Trace ID: \(span.traceId)")
print("Span ID: \(span.spanId)")
print("Parent Span: \(span.parentSpanId ?? "none")")
```

### Performance Tracking

```swift
// Time operations
await context.startTimer("database.query")
let results = try await database.query(sql)
await context.endTimer("database.query")

// Record metrics
await context.recordMetric("cache.hit_rate", value: 0.95, unit: "ratio")
await context.recordMetric("queue.depth", value: 42, unit: "items")

// Get performance context
let perfContext = await context.getOrCreatePerformanceContext()
let queryTime = perfContext.getMetric("database.query")?.duration
```

### Custom Event Emission

```swift
// Emit business events
await context.emitCustomEvent("order.placed", properties: [
    "order_id": orderId,
    "amount": 99.99,
    "currency": "USD",
    "items_count": 3
])

// Set observability data
await context.setObservabilityData("user.segment", value: "premium")
let segment = await context.getObservabilityData("user.segment") as? String
```

## 🌐 Distributed Tracing

### Trace Propagation

```swift
struct DistributedTracingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        // Get or create trace context
        let span = await context.getOrCreateSpanContext(operation: String(describing: T.self))
        
        // Add service tags
        let serviceSpan = SpanContext(
            traceId: span.traceId,
            spanId: UUID().uuidString,
            parentSpanId: span.spanId,
            operation: span.operation,
            tags: span.tags.merging([
                "service.name": "user-service",
                "service.version": "1.2.0",
                "service.environment": "production"
            ]) { _, new in new }
        )
        
        await context.set(serviceSpan, for: SpanContextKey.self)
        
        // Propagate to HTTP headers
        if let httpClient = await context.get(HTTPClientKey.self) {
            httpClient.headers["X-Trace-ID"] = span.traceId
            httpClient.headers["X-Parent-Span-ID"] = span.spanId
            httpClient.headers["X-Span-ID"] = serviceSpan.spanId
        }
        
        return try await next(command, context)
    }
}
```

### OpenTelemetry Integration

```swift
class OpenTelemetryObserver: PipelineObserver {
    private let tracer: Tracer
    
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        let span = tracer.spanBuilder(String(describing: T.self))
            .setSpanKind(.server)
            .setAttribute("pipeline.type", pipelineType)
            .setAttribute("command.type", String(describing: T.self))
            .setAttribute("user.id", metadata.userId ?? "anonymous")
            .startSpan()
        
        // Store span in context for later use
        await SpanStorage.store(correlationId: metadata.correlationId ?? "", span: span)
    }
}
```

## 📊 Performance Monitoring

### Performance Tracking Middleware

```swift
let performanceMiddleware = PerformanceTrackingMiddleware(
    thresholds: .init(
        slowCommandThreshold: 1.0,      // Alert if > 1 second
        slowMiddlewareThreshold: 0.1,   // Alert if > 100ms
        memoryUsageThreshold: 100       // Alert if > 100MB increase
    )
)

pipeline.addMiddleware(performanceMiddleware)
```

### Performance Alerts

```swift
// Automatic alerts when thresholds exceeded
class PerformanceAlertObserver: PipelineObserver {
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        if eventName == "performance.threshold_exceeded" {
            let alertType = properties["threshold_type"] as? String ?? "unknown"
            let value = properties["value"] as? Double ?? 0
            let threshold = properties["threshold"] as? Double ?? 0
            
            await alertService.send(.performance(
                type: alertType,
                value: value,
                threshold: threshold,
                correlationId: correlationId
            ))
        }
    }
}
```

## 📈 Custom Metrics

### Business Metrics

```swift
struct OrderProcessingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        guard let orderCommand = command as? ProcessOrderCommand else {
            return try await next(command, context)
        }
        
        // Track order metrics
        await context.emitCustomEvent("order.processing.started", properties: [
            "order_id": orderCommand.orderId,
            "total_amount": orderCommand.totalAmount,
            "item_count": orderCommand.items.count
        ])
        
        do {
            let result = try await next(command, context)
            
            await context.emitCustomEvent("order.processing.completed", properties: [
                "order_id": orderCommand.orderId,
                "processing_time": Date().timeIntervalSince(startTime)
            ])
            
            return result
        } catch {
            await context.emitCustomEvent("order.processing.failed", properties: [
                "order_id": orderCommand.orderId,
                "error": error.localizedDescription
            ])
            throw error
        }
    }
}
```

### A/B Testing Metrics

```swift
struct ABTestingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        // Determine experiment variant
        let userId = await context.commandMetadata.userId ?? "anonymous"
        let variant = getExperimentVariant(userId: userId, experiment: "new_checkout_flow")
        
        // Track variant assignment
        await context.emitCustomEvent("experiment.assigned", properties: [
            "experiment": "new_checkout_flow",
            "variant": variant,
            "user_id": userId
        ])
        
        // Store variant in context for other middleware
        await context.setObservabilityData("experiment.variant", value: variant)
        
        return try await next(command, context)
    }
}
```

## 🔒 Security Observability

### Security Event Tracking

```swift
class SecurityObserver: PipelineObserver {
    private let securityMonitor: SecurityMonitor
    
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        // Track security-relevant failures
        switch error {
        case is AuthenticationError:
            await securityMonitor.recordAuthFailure(
                userId: metadata.userId,
                ip: metadata.sourceIP
            )
            
        case is AuthorizationError:
            await securityMonitor.recordAuthorizationFailure(
                userId: metadata.userId,
                resource: String(describing: T.self)
            )
            
        case is RateLimitError:
            await securityMonitor.recordRateLimitViolation(
                identifier: metadata.userId ?? metadata.sourceIP ?? "unknown"
            )
            
        default:
            break
        }
    }
}
```

### Threat Detection

```swift
struct ThreatDetectionObserver: PipelineObserver {
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        if eventName.hasPrefix("security.") {
            // Analyze for threat patterns
            let threatScore = await analyzer.analyze(
                event: eventName,
                properties: properties,
                correlationId: correlationId
            )
            
            if threatScore > 0.8 {
                await alertService.sendThreatAlert(
                    score: threatScore,
                    event: eventName,
                    correlationId: correlationId
                )
            }
        }
    }
}
```

## 💡 Best Practices

### 1. Use Correlation IDs

Always include correlation IDs for request tracing:

```swift
let metadata = DefaultCommandMetadata(
    correlationId: UUID().uuidString,
    userId: currentUser.id
)
```

### 2. Batch Observer Operations

Observers should batch operations when possible:

```swift
class BatchingMetricsObserver: PipelineObserver {
    private var buffer: [Metric] = []
    private let batchSize = 100
    
    func pipelineDidExecute<T: Command>(...) async {
        buffer.append(Metric(...))
        
        if buffer.count >= batchSize {
            await flushMetrics()
        }
    }
    
    private func flushMetrics() async {
        await metricsClient.sendBatch(buffer)
        buffer.removeAll()
    }
}
```

### 3. Use Structured Properties

Keep event properties consistent:

```swift
// Good: Structured and consistent
await context.emitCustomEvent("user.action", properties: [
    "action_type": "purchase",
    "user_id": userId,
    "timestamp": Date().timeIntervalSince1970,
    "session_id": sessionId
])

// Bad: Inconsistent structure
await context.emitCustomEvent("user did something", properties: [
    "what": "bought",
    "who": userId,
    "when": "now"
])
```

### 4. Respect Privacy

Never log sensitive information:

```swift
// Good: Masked sensitive data
await context.emitCustomEvent("payment.processed", properties: [
    "card_last_four": "***1234",
    "amount": 99.99
])

// Bad: Exposing sensitive data
await context.emitCustomEvent("payment.processed", properties: [
    "card_number": "1234567812345678",  // Never log this!
    "cvv": "123"                        // Never log this!
])
```

## 🔧 Integration Examples

### Prometheus Integration

```swift
class PrometheusObserver: PipelineObserver {
    private let registry: PrometheusRegistry
    
    private lazy var commandCounter = registry.counter(
        name: "pipeline_commands_total",
        help: "Total number of commands processed"
    )
    
    private lazy var commandDuration = registry.histogram(
        name: "pipeline_command_duration_seconds",
        help: "Command execution duration in seconds"
    )
    
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        commandCounter.inc([
            "command": String(describing: T.self),
            "pipeline": pipelineType,
            "status": "success"
        ])
        
        commandDuration.observe(duration, [
            "command": String(describing: T.self),
            "pipeline": pipelineType
        ])
    }
}
```

### Elasticsearch Integration

```swift
class ElasticsearchObserver: PipelineObserver {
    private let client: ElasticsearchClient
    
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        let document = EventDocument(
            timestamp: Date(),
            eventName: eventName,
            properties: properties,
            correlationId: correlationId,
            service: "pipeline-service",
            environment: Configuration.environment
        )
        
        await client.index(
            index: "pipeline-events-\(Date().format("yyyy.MM.dd"))",
            document: document
        )
    }
}
```

### CloudWatch Integration

```swift
class CloudWatchObserver: PipelineObserver {
    private let client: CloudWatchClient
    
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await client.putMetricData(
            namespace: "PipelineKit",
            metricData: [
                MetricDatum(
                    metricName: "CommandDuration",
                    value: duration * 1000, // Convert to milliseconds
                    unit: .milliseconds,
                    dimensions: [
                        Dimension(name: "Command", value: String(describing: T.self)),
                        Dimension(name: "Pipeline", value: pipelineType)
                    ]
                )
            ]
        )
    }
}
```

## 🚀 Getting Started

### Quick Start with Built-in Observers

1. **Development Setup**
   ```swift
   // Comprehensive development observability
   let pipeline = ObservablePipeline(
       wrapping: DefaultPipeline(handler: handler),
       observers: [
           ConsoleObserver.development(),  // Pretty console output
           MemoryObserver()                // Event storage for debugging
       ]
   )
   ```

2. **Production Setup**
   ```swift
   // Production-ready observability
   let pipeline = ObservablePipeline(
       wrapping: DefaultPipeline(handler: handler),
       observers: [
           OSLogObserver.production(),                    // System logging
           MetricsObserver(backend: datadogBackend),      // Metrics
           ConditionalObserver.onlyFailures(              // Alert on errors
               observer: alertingObserver
           )
       ]
   )
   ```

3. **Testing Setup**
   ```swift
   // Observability for tests
   let memoryObserver = MemoryObserver()
   let pipeline = ObservablePipeline(
       wrapping: DefaultPipeline(handler: handler),
       observers: [memoryObserver]
   )
   
   // Execute and verify
   _ = try await pipeline.execute(command, metadata: metadata)
   
   // Check results
   let events = await memoryObserver.allEvents()
   XCTAssertEqual(events.count, expectedEventCount)
   
   let stats = await memoryObserver.statistics()
   XCTAssertEqual(stats.successfulExecutions, 1)
   ```

4. **Custom Observer Combinations**
   ```swift
   // Mix and match observers for your needs
   let observers: [PipelineObserver] = [
       // Console output for critical commands only
       ConditionalObserver.forCommands(
           "PaymentCommand", "RefundCommand",
           observer: ConsoleObserver(style: .detailed, level: .info)
       ),
       
       // Metrics for all commands
       MetricsObserver(
           backend: prometheusBackend,
           configuration: .init(
               metricPrefix: "myapp",
               globalTags: ["env": "prod"]
           )
       ),
       
       // Memory storage for recent events
       MemoryObserver(options: .init(
           maxEvents: 1000,
           cleanupInterval: 300  // 5 minutes
       ))
   ]
   
   let pipeline = ObservablePipeline(
       wrapping: YourPipeline(handler: handler),
       observers: observers
   )
   ```

---

With PipelineKit's observability features, you have complete visibility into your command execution pipeline, enabling you to build reliable, performant, and secure applications.