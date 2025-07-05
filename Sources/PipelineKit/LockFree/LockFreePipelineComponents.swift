import Foundation
import Atomics

/// High-performance pipeline using lock-free components
public actor LockFreePipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    private let handler: H
    private let middlewares: [any Middleware]
    private let metrics = LockFreeMetricsCollector()
    private let commandQueue = LockFreeQueue<PendingCommand<C>>()
    private var processingTask: Task<Void, Never>?
    
    private struct PendingCommand<T: Command> {
        let command: T
        let context: CommandContext
        let continuation: CheckedContinuation<T.Result, Error>
    }
    
    public init(handler: H, middlewares: [any Middleware] = []) {
        self.handler = handler
        self.middlewares = middlewares
        
        // Start processing loop
        self.processingTask = Task {
            await processCommands()
        }
    }
    
    deinit {
        processingTask?.cancel()
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.invalidCommandType(command: command)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingCommand(
                command: typedCommand,
                context: context,
                continuation: continuation
            )
            commandQueue.enqueue(pending)
        } as! T.Result
    }
    
    private func processCommands() async {
        while !Task.isCancelled {
            if let pending = commandQueue.dequeue() {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                do {
                    let result = try await executeCommand(
                        pending.command,
                        context: pending.context
                    )
                    
                    let latency = CFAbsoluteTimeGetCurrent() - startTime
                    metrics.recordExecution(latency: latency, success: true)
                    
                    pending.continuation.resume(returning: result)
                } catch {
                    let latency = CFAbsoluteTimeGetCurrent() - startTime
                    metrics.recordExecution(latency: latency, success: false)
                    
                    pending.continuation.resume(throwing: error)
                }
            } else {
                // No commands, yield to prevent spinning
                await Task.yield()
            }
        }
    }
    
    private func executeCommand(
        _ command: C,
        context: CommandContext
    ) async throws -> C.Result {
        // Build middleware chain
        var next: @Sendable (C, CommandContext) async throws -> C.Result = { cmd, ctx in
            try await self.handler.handle(cmd)
        }
        
        for middleware in middlewares.reversed() {
            let currentNext = next
            next = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: currentNext)
            }
        }
        
        return try await next(command, context)
    }
    
    /// Get current performance metrics
    public var performanceMetrics: LockFreeMetricsCollector.Metrics {
        metrics.metrics
    }
    
    /// Add middleware (must be called before processing starts)
    public func addMiddleware(_ middleware: any Middleware) async {
        // In production, implement thread-safe middleware addition
        fatalError("Dynamic middleware addition not yet implemented for lock-free pipeline")
    }
}

/// Extension to add lock-free capabilities to existing pipelines
public extension Pipeline {
    /// Create a lock-free wrapper around this pipeline
    func withLockFreeExecution() -> some Pipeline {
        LockFreeWrapper(basePipeline: self)
    }
}

/// Wrapper to add lock-free execution to any pipeline
private struct LockFreeWrapper: Pipeline {
    private let basePipeline: any Pipeline
    private let queue = LockFreeQueue<PendingExecution>()
    private let executor: Task<Void, Never>
    
    private struct PendingExecution {
        let execute: @Sendable () async throws -> Any
        let continuation: CheckedContinuation<Any, Error>
    }
    
    init(basePipeline: any Pipeline) {
        self.basePipeline = basePipeline
        
        // Start executor
        self.executor = Task {
            await executeLoop()
        }
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingExecution(
                execute: {
                    try await basePipeline.execute(command, context: context)
                },
                continuation: continuation
            )
            queue.enqueue(pending)
        } as! T.Result
    }
    
    private func executeLoop() async {
        while !Task.isCancelled {
            if let pending = queue.dequeue() {
                do {
                    let result = try await pending.execute()
                    pending.continuation.resume(returning: result)
                } catch {
                    pending.continuation.resume(throwing: error)
                }
            } else {
                await Task.yield()
            }
        }
    }
}