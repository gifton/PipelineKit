import Foundation
import PipelineKitCore

/// Middleware that adds observability to pipeline execution
public struct PipelineObservabilityMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing
    private let observerRegistry: ObserverRegistry
    private let pipelineTypeName: String
    
    public init(
        observers: [PipelineObserver],
        pipelineTypeName: String = "Pipeline"
    ) {
        self.observerRegistry = ObserverRegistry(observers: observers)
        self.pipelineTypeName = pipelineTypeName
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        let metadata = context.commandMetadata
        
        // Store observer registry in context for nested middleware
        context.set(observerRegistry, for: ObserverRegistryKey.self)
        
        // Notify observers that pipeline execution is starting
        await observerRegistry.notifyPipelineWillExecute(command, metadata: metadata, pipelineType: pipelineTypeName)
        
        do {
            // Execute the next middleware/handler
            let result = try await next(command, context)
            
            // Calculate duration and notify success
            let duration = Date().timeIntervalSince(startTime)
            await observerRegistry.notifyPipelineDidExecute(
                command,
                result: result,
                metadata: metadata,
                pipelineType: pipelineTypeName,
                duration: duration
            )
            
            return result
            
        } catch {
            // Calculate duration and notify failure
            let duration = Date().timeIntervalSince(startTime)
            await observerRegistry.notifyPipelineDidFail(
                command,
                error: error,
                metadata: metadata,
                pipelineType: pipelineTypeName,
                duration: duration
            )
            
            throw error
        }
    }
}

/// A decorator that adds observability to any pipeline implementation
///
/// Thread-safe because:
/// - Wrapped pipeline is required to be Sendable (Pipeline protocol requires it)
/// - Middleware is immutable and Sendable
/// - No mutable state is maintained
public final class ObservablePipeline: Pipeline, @unchecked Sendable {
    private let wrappedPipeline: any Pipeline
    private let middleware: PipelineObservabilityMiddleware
    
    public init(
        wrapping pipeline: any Pipeline,
        observers: [PipelineObserver] = [],
        pipelineTypeName: String? = nil
    ) {
        self.wrappedPipeline = pipeline
        self.middleware = PipelineObservabilityMiddleware(
            observers: observers,
            pipelineTypeName: pipelineTypeName ?? String(describing: type(of: pipeline))
        )
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        // Use the middleware to wrap the pipeline execution
        return try await middleware.execute(command, context: context) { cmd, ctx in
            try await self.wrappedPipeline.execute(cmd, context: ctx)
        }
    }
}


// MARK: - Observable Middleware Decorator

/// A decorator that adds observability to any middleware
public struct ObservableMiddlewareDecorator<M: Middleware>: Middleware {
    private let wrappedMiddleware: M
    private let middlewareName: String
    private let order: Int
    
    public var priority: ExecutionPriority {
        wrappedMiddleware.priority
    }
    
    public init(wrapping middleware: M, name: String? = nil, order: Int = 0) {
        self.wrappedMiddleware = middleware
        self.middlewareName = name ?? String(describing: type(of: middleware))
        self.order = order
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let metadata = context.commandMetadata
        let correlationId = ObservabilityUtils.extractCorrelationId(from: metadata)
        let startTime = Date()
        
        // Get observer registry from context if available
        let observerRegistry = context.get(ObserverRegistryKey.self)
        
        // Notify that middleware is starting
        await observerRegistry?.notifyMiddlewareWillExecute(middlewareName, order: order, correlationId: correlationId)
        
        do {
            // Execute the wrapped middleware
            let result = try await wrappedMiddleware.execute(command, context: context, next: next)
            
            // Calculate duration and notify success
            let duration = Date().timeIntervalSince(startTime)
            await observerRegistry?.notifyMiddlewareDidExecute(
                middlewareName,
                order: order,
                correlationId: correlationId,
                duration: duration
            )
            
            return result
            
        } catch {
            // Calculate duration and notify failure
            let duration = Date().timeIntervalSince(startTime)
            await observerRegistry?.notifyMiddlewareDidFail(
                middlewareName,
                order: order,
                correlationId: correlationId,
                error: error,
                duration: duration
            )
            
            throw error
        }
    }
}

// MARK: - Observable Context-Aware Middleware Decorator

/// A decorator that adds observability to context-aware middleware
public struct ObservableContextAwareMiddlewareDecorator<M: Middleware>: Middleware {
    private let wrappedMiddleware: M
    private let middlewareName: String
    private let order: Int
    
    public var priority: ExecutionPriority {
        wrappedMiddleware.priority
    }
    
    public init(wrapping middleware: M, name: String? = nil, order: Int = 0) {
        self.wrappedMiddleware = middleware
        self.middlewareName = name ?? String(describing: type(of: middleware))
        self.order = order
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        let startTime = Date()
        
        // Get span context from the command context
        let spanContext = context.getOrCreateSpanContext(operation: "middleware_execution")
        let correlationId = spanContext.traceId
        
        // Get observer registry from context
        let observerRegistry = context.getObserverRegistry()
        
        // Create child span for this middleware
        let _ = context.createChildSpan(
            operation: middlewareName,
            tags: ["middleware.name": middlewareName, "middleware.order": String(order)]
        )
        
        // Start performance timer
        context.startTimer("middleware.\(middlewareName)")
        
        // Notify that middleware is starting
        await observerRegistry?.notifyMiddlewareWillExecute(middlewareName, order: order, correlationId: correlationId)
        
        do {
            // Execute the wrapped middleware
            let result = try await wrappedMiddleware.execute(command, context: context, next: next)
            
            // End performance timer
            context.endTimer("middleware.\(middlewareName)")
            
            // Calculate duration and notify success
            let duration = Date().timeIntervalSince(startTime)
            await observerRegistry?.notifyMiddlewareDidExecute(
                middlewareName,
                order: order,
                correlationId: correlationId,
                duration: duration
            )
            
            return result
            
        } catch {
            // End performance timer
            context.endTimer("middleware.\(middlewareName)")
            
            // Calculate duration and notify failure
            let duration = Date().timeIntervalSince(startTime)
            await observerRegistry?.notifyMiddlewareDidFail(
                middlewareName,
                order: order,
                correlationId: correlationId,
                error: error,
                duration: duration
            )
            
            throw error
        }
    }
}

// MARK: - Builder Extensions

public extension Pipeline {
    /// Wraps this pipeline with observability
    func withObservability(observers: [PipelineObserver] = []) -> ObservablePipeline {
        return ObservablePipeline(wrapping: self, observers: observers)
    }
}

public extension Middleware {
    /// Wraps this middleware with observability
    func withObservability(name: String? = nil, order: Int = 0) -> ObservableMiddlewareDecorator<Self> {
        return ObservableMiddlewareDecorator(wrapping: self, name: name, order: order)
    }
}

public extension Middleware {
    /// Wraps this middleware with observability (context-aware version)
    func withContextAwareObservability(name: String? = nil, order: Int = 0) -> ObservableContextAwareMiddlewareDecorator<Self> {
        return ObservableContextAwareMiddlewareDecorator(wrapping: self, name: name, order: order)
    }
}

// MARK: - Observability Configuration

/// Configuration for setting up observability in pipelines
public struct ObservabilityConfiguration: Sendable {
    public let observers: [PipelineObserver]
    public let enableMiddlewareObservability: Bool
    public let enableHandlerObservability: Bool
    public let enablePerformanceMetrics: Bool
    public let enableDistributedTracing: Bool
    
    public init(
        observers: [PipelineObserver] = [],
        enableMiddlewareObservability: Bool = true,
        enableHandlerObservability: Bool = true,
        enablePerformanceMetrics: Bool = true,
        enableDistributedTracing: Bool = false
    ) {
        self.observers = observers
        self.enableMiddlewareObservability = enableMiddlewareObservability
        self.enableHandlerObservability = enableHandlerObservability
        self.enablePerformanceMetrics = enablePerformanceMetrics
        self.enableDistributedTracing = enableDistributedTracing
    }
    
    /// Creates a development configuration with comprehensive observability
    public static func development() -> ObservabilityConfiguration {
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            return ObservabilityConfiguration(
                observers: [
                    OSLogObserver.development()
                ],
                enableMiddlewareObservability: true,
                enableHandlerObservability: true,
                enablePerformanceMetrics: true,
                enableDistributedTracing: true
            )
        } else {
            // Fallback for older platforms without OSLogObserver
            return ObservabilityConfiguration(
                observers: [],
                enableMiddlewareObservability: true,
                enableHandlerObservability: true,
                enablePerformanceMetrics: true,
                enableDistributedTracing: true
            )
        }
    }
    
    /// Creates a production configuration with optimized observability
    public static func production() -> ObservabilityConfiguration {
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            return ObservabilityConfiguration(
                observers: [
                    OSLogObserver.production()
                ],
                enableMiddlewareObservability: false,
                enableHandlerObservability: true,
                enablePerformanceMetrics: true,
                enableDistributedTracing: false
            )
        } else {
            // Fallback for older platforms without OSLogObserver
            return ObservabilityConfiguration(
                observers: [],
                enableMiddlewareObservability: false,
                enableHandlerObservability: true,
                enablePerformanceMetrics: true,
                enableDistributedTracing: false
            )
        }
    }
}