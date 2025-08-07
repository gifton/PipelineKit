import Foundation
#if canImport(Darwin)
import Darwin
#endif
import PipelineKitCore

// MARK: - Core Observability Middleware

/// Middleware that automatically instruments command execution with observability
public struct ObservabilityMiddleware: Middleware {
    public var priority: ExecutionPriority { .postProcessing }
    
    private let configuration: ObservabilityConfiguration
    
    public init(configuration: ObservabilityConfiguration = .development()) {
        self.configuration = configuration
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Set up observability context
        await setupObservabilityContext(for: command, context: context)
        
        // Execute with observability tracking
        return try await executeWithObservability(command, context: context, next: next)
    }
    
    private func setupObservabilityContext<T: Command>(for command: T, context: CommandContext) async {
        // Set up observer registry
        let registry = ObserverRegistry(observers: configuration.observers)
        context.setObserverRegistry(registry)
        
        // Create root span for this command execution
        let commandName = String(describing: type(of: command))
        let span = context.getOrCreateSpanContext(operation: commandName)
        
        // Add command-specific tags
        var tags = ObservabilityUtils.createTagsFromMetadata(context.commandMetadata)
        tags["command.type"] = commandName
        tags["command.id"] = UUID().uuidString
        
        // Update span with tags
        let updatedSpan = SpanContext(
            traceId: span.traceId,
            spanId: span.spanId,
            parentSpanId: span.parentSpanId,
            operation: span.operation,
            startTime: span.startTime,
            tags: tags
        )
        context[ObservabilityContextKeys.spanContext] = updatedSpan
        
        // Initialize performance context
        if configuration.enablePerformanceMetrics {
            let perfContext = PerformanceContext()
            context[ObservabilityContextKeys.performanceContext] = perfContext
            context.startTimer("command.total_duration")
        }
        
        // Set up observability data
        context.setObservabilityData("command.start_time", value: Date())
        context.setObservabilityData("command.type", value: commandName)
        context.setObservabilityData("observability.enabled", value: true)
    }
    
    private func executeWithObservability<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        _ = context.getOrCreateSpanContext(operation: "command_execution")
        
        // Handle command observability setup
        await command.setupObservability(context: context)
        
        do {
            // Execute the command
            let result = try await next(command, context)
            
            // Record success metrics
            await recordSuccessMetrics(for: command, result: result, context: context, startTime: startTime)
            
            // Handle command observability completion
            await command.observabilityDidComplete(context: context, result: result)
            
            return result
        } catch {
            // Record failure metrics
            await recordFailureMetrics(for: command, error: error, context: context, startTime: startTime)
            
            // Handle command observability failure
            await command.observabilityDidFail(context: context, error: error)
            
            throw error
        }
    }
    
    private func recordSuccessMetrics<T: Command, Result>(
        for command: T,
        result: Result,
        context: CommandContext,
        startTime: Date
    ) async {
        let duration = Date().timeIntervalSince(startTime)
        
        // Record performance metrics
        if configuration.enablePerformanceMetrics {
            context.endTimer("command.total_duration")
            context.recordPerformanceMetric("command.duration", value: duration, unit: "seconds")
            context.recordPerformanceMetric("command.success", value: 1, unit: "count")
        }
        
        // Emit custom event
        context.emitCustomEvent("command.completed", properties: [
            "command_type": String(describing: type(of: command)),
            "result_type": String(describing: type(of: result)),
            "duration_seconds": duration,
            "success": true
        ] as [String: any Sendable])
    }
    
    private func recordFailureMetrics<T: Command>(
        for command: T,
        error: Error,
        context: CommandContext,
        startTime: Date
    ) async {
        let duration = Date().timeIntervalSince(startTime)
        
        // Record performance metrics
        if configuration.enablePerformanceMetrics {
            context.endTimer("command.total_duration")
            context.recordPerformanceMetric("command.duration", value: duration, unit: "seconds")
            context.recordPerformanceMetric("command.failure", value: 1, unit: "count")
        }
        
        // Emit custom event
        context.emitCustomEvent("command.failed", properties: [
            "command_type": String(describing: type(of: command)),
            "error_type": String(describing: type(of: error)),
            "error_message": error.localizedDescription,
            "duration_seconds": duration,
            "success": false
        ] as [String: any Sendable])
    }
}

// MARK: - Observability Configuration

/// Configuration for observability features
public struct ObservabilityConfiguration: Sendable {
    public let observers: [any PipelineObserver]
    public let enablePerformanceMetrics: Bool
    public let enableDistributedTracing: Bool
    public let enableCustomEvents: Bool
    
    public init(
        observers: [any PipelineObserver] = [],
        enablePerformanceMetrics: Bool = true,
        enableDistributedTracing: Bool = true,
        enableCustomEvents: Bool = true
    ) {
        self.observers = observers
        self.enablePerformanceMetrics = enablePerformanceMetrics
        self.enableDistributedTracing = enableDistributedTracing
        self.enableCustomEvents = enableCustomEvents
    }
    
    /// Development configuration with console output
    public static func development() -> ObservabilityConfiguration {
        ObservabilityConfiguration(observers: [ConsoleObserver()])
    }
    
    /// Production configuration with metrics backend
    public static func production(backend: MetricsBackend? = nil) -> ObservabilityConfiguration {
        if let backend = backend {
            let metricsObserver = MetricsObserver(backend: backend)
            return ObservabilityConfiguration(observers: [metricsObserver])
        } else {
            return ObservabilityConfiguration(observers: [])
        }
    }
}

// MARK: - Performance Tracking Middleware

/// Specialized middleware for detailed performance tracking
public struct PerformanceTrackingMiddleware: Middleware {
    public var priority: ExecutionPriority { .postProcessing }
    
    private let thresholds: PerformanceThresholds
    
    public init(thresholds: PerformanceThresholds = .default) {
        self.thresholds = thresholds
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let initialMemory = getMemoryUsage()
        
        context.startTimer("performance.command_execution")
        context.recordPerformanceMetric("performance.memory_start", value: Double(initialMemory), unit: "MB")
        
        do {
            let result = try await next(command, context)
            
            // Record final metrics
            let duration = Date().timeIntervalSince(startTime)
            let finalMemory = getMemoryUsage()
            let memoryDelta = finalMemory - initialMemory
            
            context.endTimer("performance.command_execution")
            context.recordPerformanceMetric("performance.memory_end", value: Double(finalMemory), unit: "MB")
            context.recordPerformanceMetric("performance.memory_delta", value: Double(memoryDelta), unit: "MB")
            
            // Check thresholds
            await checkPerformanceThresholds(
                command: command,
                context: context,
                duration: duration,
                memoryDelta: memoryDelta
            )
            
            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            let finalMemory = getMemoryUsage()
            
            context.endTimer("performance.command_execution")
            context.recordPerformanceMetric("performance.memory_end", value: Double(finalMemory), unit: "MB")
            
            context.emitCustomEvent("performance.command_failed", properties: [
                "duration": duration,
                "error": error.localizedDescription
            ] as [String: any Sendable])
            
            throw error
        }
    }
    
    private func checkPerformanceThresholds<T: Command>(
        command: T,
        context: CommandContext,
        duration: TimeInterval,
        memoryDelta: Int
    ) async {
        // Check slow command threshold
        if duration > thresholds.slowCommandThreshold {
            context.emitCustomEvent("performance.slow_command", properties: [
                "command_type": String(describing: type(of: command)),
                "duration": duration,
                "threshold": thresholds.slowCommandThreshold
            ] as [String: any Sendable])
        }
        
        // Check memory usage threshold
        if memoryDelta > thresholds.memoryUsageThreshold {
            context.emitCustomEvent("performance.high_memory_usage", properties: [
                "command_type": String(describing: type(of: command)),
                "memory_delta": memoryDelta,
                "threshold": thresholds.memoryUsageThreshold
            ] as [String: any Sendable])
        }
    }
    
    private func getMemoryUsage() -> Int {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size / 1024 / 1024) : 0
        #else
        return 0 // Memory tracking not available on this platform
        #endif
    }
}

// MARK: - Distributed Tracing Middleware

/// Middleware for distributed tracing support
public struct DistributedTracingMiddleware: Middleware {
    public var priority: ExecutionPriority { .preProcessing }
    
    private let propagator: TracePropagator
    
    public init(propagator: TracePropagator = W3CTracePropagator()) {
        self.propagator = propagator
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Extract or create trace context
        let span = context.getOrCreateSpanContext(operation: String(describing: type(of: command)))
        
        // Add distributed tracing headers
        var updatedSpan = span
        if let parentContext = propagator.extract(from: context.metadata) {
            updatedSpan = SpanContext(
                traceId: parentContext.traceId,
                spanId: UUID().uuidString,
                parentSpanId: parentContext.spanId,
                operation: span.operation,
                startTime: span.startTime,
                tags: span.tags
            )
        }
        
        context[ObservabilityContextKeys.spanContext] = updatedSpan
        
        // Execute with distributed tracing context
        return try await next(command, context)
    }
}

// MARK: - Custom Event Middleware

/// Middleware for custom event emission
public struct CustomEventMiddleware: Middleware {
    public var priority: ExecutionPriority { .postProcessing }
    
    private let eventPrefix: String
    
    public init(eventPrefix: String = "custom") {
        self.eventPrefix = eventPrefix
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Emit command started event
        context.emitCustomEvent("\(eventPrefix).command_started", properties: [
            "command_type": String(describing: type(of: command)),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ] as [String: any Sendable])
        
        do {
            let result = try await next(command, context)
            
            // Emit command completed event
            context.emitCustomEvent("\(eventPrefix).command_completed", properties: [
                "command_type": String(describing: type(of: command)),
                "result_type": String(describing: type(of: result)),
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ] as [String: any Sendable])
            
            return result
        } catch {
            // Emit command failed event
            context.emitCustomEvent("\(eventPrefix).command_failed", properties: [
                "command_type": String(describing: type(of: command)),
                "error_type": String(describing: type(of: error)),
                "error_message": error.localizedDescription,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ] as [String: any Sendable])
            
            throw error
        }
    }
}

// MARK: - Trace Propagation

/// Protocol for trace context propagation
public protocol TracePropagator: Sendable {
    func extract(from metadata: [String: any Sendable]) -> (traceId: String, spanId: String)?
    func inject(traceId: String, spanId: String, into metadata: inout [String: any Sendable])
}

/// W3C Trace Context propagator
public struct W3CTracePropagator: TracePropagator {
    public init() {}
    
    public func extract(from metadata: [String: any Sendable]) -> (traceId: String, spanId: String)? {
        guard let traceparent = metadata["traceparent"] as? String else { return nil }
        
        let parts = traceparent.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        
        return (traceId: String(parts[1]), spanId: String(parts[2]))
    }
    
    public func inject(traceId: String, spanId: String, into metadata: inout [String: any Sendable]) {
        metadata["traceparent"] = "00-\(traceId)-\(spanId)-01"
    }
}