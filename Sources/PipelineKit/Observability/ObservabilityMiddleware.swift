import Foundation

// MARK: - Core Observability Middleware

/// Middleware that automatically instruments command execution with observability
public struct ObservabilityMiddleware: ContextAwareMiddleware, PrioritizedMiddleware {
    
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .tracing }
    
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
        await context.setObserverRegistry(registry)
        
        // Create root span for this command execution
        let commandName = String(describing: type(of: command))
        let span = await context.getOrCreateSpanContext(operation: commandName)
        
        // Add command-specific tags
        var tags = await ObservabilityUtils.createTagsFromMetadata(context.commandMetadata)
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
        await context.set(updatedSpan, for: SpanContextKey.self)
        
        // Initialize performance context
        if configuration.enablePerformanceMetrics {
            let perfContext = PerformanceContext()
            await context.set(perfContext, for: PerformanceContextKey.self)
            await context.startTimer("command.total_duration")
        }
        
        // Set up observability data
        await context.setObservabilityData("command.start_time", value: Date())
        await context.setObservabilityData("command.type", value: commandName)
        await context.setObservabilityData("observability.enabled", value: true)
    }
    
    private func executeWithObservability<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        let startTime = Date()
        let _ = await context.getOrCreateSpanContext(operation: "command_execution")
        
        // Handle observable commands
        if let observableCommand = command as? any ObservableCommand {
            await observableCommand.setupObservability(context: context)
        }
        
        do {
            // Execute the command
            let result = try await next(command, context)
            
            // Record success metrics
            await recordSuccessMetrics(for: command, result: result, context: context, startTime: startTime)
            
            // Handle observable command completion
            if let observableCommand = command as? any ObservableCommand {
                await observableCommand.observabilityDidComplete(context: context, result: result)
            }
            
            return result
            
        } catch {
            // Record failure metrics
            await recordFailureMetrics(for: command, error: error, context: context, startTime: startTime)
            
            // Handle observable command failure
            if let observableCommand = command as? any ObservableCommand {
                await observableCommand.observabilityDidFail(context: context, error: error)
            }
            
            throw error
        }
    }
    
    private func recordSuccessMetrics<T: Command>(
        for command: T,
        result: T.Result,
        context: CommandContext,
        startTime: Date
    ) async {
        let duration = Date().timeIntervalSince(startTime)
        
        if configuration.enablePerformanceMetrics {
            await context.endTimer("command.total_duration")
            await context.recordMetric("command.duration", value: duration, unit: "seconds")
            await context.recordMetric("command.success", value: 1, unit: "count")
        }
        
        // Emit custom event
        await context.emitCustomEvent("command.completed", properties: [
            "command_type": String(describing: type(of: command)),
            "result_type": String(describing: type(of: result)),
            "duration": duration,
            "success": true
        ])
    }
    
    private func recordFailureMetrics<T: Command>(
        for command: T,
        error: Error,
        context: CommandContext,
        startTime: Date
    ) async {
        let duration = Date().timeIntervalSince(startTime)
        
        if configuration.enablePerformanceMetrics {
            await context.endTimer("command.total_duration")
            await context.recordMetric("command.duration", value: duration, unit: "seconds")
            await context.recordMetric("command.failure", value: 1, unit: "count")
        }
        
        // Emit custom event
        await context.emitCustomEvent("command.failed", properties: [
            "command_type": String(describing: type(of: command)),
            "error_type": String(describing: type(of: error)),
            "error_message": error.localizedDescription,
            "duration": duration,
            "success": false
        ])
    }
    
}

// MARK: - Performance Tracking Middleware

/// Specialized middleware for detailed performance tracking
public struct PerformanceTrackingMiddleware: ContextAwareMiddleware, PrioritizedMiddleware {
    
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .monitoring }
    
    private let thresholds: PerformanceThresholds
    
    public struct PerformanceThresholds: Sendable {
        public let slowCommandThreshold: TimeInterval
        public let slowMiddlewareThreshold: TimeInterval
        public let memoryUsageThreshold: Int // MB
        
        public init(
            slowCommandThreshold: TimeInterval = 1.0,
            slowMiddlewareThreshold: TimeInterval = 0.1,
            memoryUsageThreshold: Int = 100
        ) {
            self.slowCommandThreshold = slowCommandThreshold
            self.slowMiddlewareThreshold = slowMiddlewareThreshold
            self.memoryUsageThreshold = memoryUsageThreshold
        }
    }
    
    public init(thresholds: PerformanceThresholds = PerformanceThresholds()) {
        self.thresholds = thresholds
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        let startTime = Date()
        let initialMemory = getCurrentMemoryUsage()
        
        // Start detailed performance tracking
        await context.startTimer("performance.command_execution")
        await context.recordMetric("performance.memory_start", value: Double(initialMemory), unit: "MB")
        
        do {
            let result = try await next(command, context)
            
            // Record performance metrics
            let duration = Date().timeIntervalSince(startTime)
            let finalMemory = getCurrentMemoryUsage()
            let memoryDelta = finalMemory - initialMemory
            
            await context.endTimer("performance.command_execution")
            await context.recordMetric("performance.memory_end", value: Double(finalMemory), unit: "MB")
            await context.recordMetric("performance.memory_delta", value: Double(memoryDelta), unit: "MB")
            
            // Check for performance issues
            await checkPerformanceThresholds(
                command: command,
                duration: duration,
                memoryDelta: memoryDelta,
                context: context
            )
            
            return result
            
        } catch {
            // Record failure performance metrics
            let duration = Date().timeIntervalSince(startTime)
            let finalMemory = getCurrentMemoryUsage()
            
            await context.endTimer("performance.command_execution")
            await context.recordMetric("performance.memory_end", value: Double(finalMemory), unit: "MB")
            
            await context.emitCustomEvent("performance.command_failed", properties: [
                "duration": duration,
                "memory_usage": finalMemory,
                "error_type": String(describing: type(of: error))
            ])
            
            throw error
        }
    }
    
    private func checkPerformanceThresholds<T: Command>(
        command: T,
        duration: TimeInterval,
        memoryDelta: Int,
        context: CommandContext
    ) async {
        
        // Check for slow command execution
        if duration > thresholds.slowCommandThreshold {
            await context.emitCustomEvent("performance.slow_command", properties: [
                "command_type": String(describing: type(of: command)),
                "duration": duration,
                "threshold": thresholds.slowCommandThreshold
            ])
        }
        
        // Check for high memory usage
        if memoryDelta > thresholds.memoryUsageThreshold {
            await context.emitCustomEvent("performance.high_memory_usage", properties: [
                "command_type": String(describing: type(of: command)),
                "memory_delta": memoryDelta,
                "threshold": thresholds.memoryUsageThreshold
            ])
        }
    }
    
    private func getCurrentMemoryUsage() -> Int {
        // Simplified memory usage calculation
        // In practice, you might use more sophisticated methods
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Int(info.resident_size) / (1024 * 1024) // Convert to MB
        }
        
        return 0
    }
}

// MARK: - Distributed Tracing Middleware

/// Middleware for distributed tracing integration
public struct DistributedTracingMiddleware: ContextAwareMiddleware, PrioritizedMiddleware {
    
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .tracing }
    
    private let serviceName: String
    private let version: String
    
    public init(serviceName: String, version: String = "1.0.0") {
        self.serviceName = serviceName
        self.version = version
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        // Create or update span context for distributed tracing
        let span = await context.getOrCreateSpanContext(operation: String(describing: type(of: command)))
        
        // Add service and version tags
        let updatedSpan = SpanContext(
            traceId: span.traceId,
            spanId: span.spanId,
            parentSpanId: span.parentSpanId,
            operation: span.operation,
            startTime: span.startTime,
            tags: span.tags.merging([
                "service.name": serviceName,
                "service.version": version,
                "span.kind": "server",
                "component": "pipelinekit"
            ]) { _, new in new }
        )
        
        await context.set(updatedSpan, for: SpanContextKey.self)
        
        // Execute with distributed tracing context
        return try await next(command, context)
    }
}

// MARK: - Custom Event Emitter Middleware

/// Middleware that allows easy emission of custom business events
public struct CustomEventEmitterMiddleware: ContextAwareMiddleware, PrioritizedMiddleware {
    
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .eventPublishing }
    
    private let eventPrefix: String
    
    public init(eventPrefix: String = "business") {
        self.eventPrefix = eventPrefix
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        // Emit command started event
        await context.emitCustomEvent("\(eventPrefix).command_started", properties: [
            "command_type": String(describing: type(of: command)),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
        
        do {
            let result = try await next(command, context)
            
            // Emit command completed event
            await context.emitCustomEvent("\(eventPrefix).command_completed", properties: [
                "command_type": String(describing: type(of: command)),
                "result_type": String(describing: type(of: result)),
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
            
            return result
            
        } catch {
            // Emit command failed event
            await context.emitCustomEvent("\(eventPrefix).command_failed", properties: [
                "command_type": String(describing: type(of: command)),
                "error_type": String(describing: type(of: error)),
                "error_message": error.localizedDescription,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
            
            throw error
        }
    }
}

