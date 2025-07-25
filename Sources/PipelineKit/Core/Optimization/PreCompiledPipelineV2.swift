import Foundation

/// A lightweight pre-compiled pipeline that minimizes overhead by avoiding runtime chain building
public final class PreCompiledPipelineV2<H: CommandHandler>: Pipeline {
    private let handler: H
    private let middleware: [any Middleware]
    private let options: PipelineOptions
    
    public init(
        handler: H,
        middleware: [any Middleware],
        options: PipelineOptions = PipelineOptions()
    ) {
        self.handler = handler
        self.middleware = middleware
        self.options = options
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        // Direct inline execution without building chains
        // This approach avoids closure allocations and chain building overhead
        
        // Type check upfront
        guard let handlerCommand = command as? H.CommandType else {
            throw PipelineErrorType.invalidCommandType
        }
        
        // Execute middleware in order with minimal overhead
        // We use indices to avoid iterator allocations
        let count = middleware.count
        
        if count == 0 {
            // Fast path: no middleware
            let result = try await handler.handle(handlerCommand)
            guard let typedResult = result as? T.Result else {
                throw PipelineErrorType.invalidCommandType
            }
            return typedResult
        }
        
        // For single middleware, avoid recursion
        if count == 1 {
            return try await middleware[0].execute(command, context: context) { cmd, ctx in
                guard let hCmd = cmd as? H.CommandType else {
                    throw PipelineErrorType.invalidCommandType
                }
                let result = try await self.handler.handle(hCmd)
                guard let typedResult = result as? T.Result else {
                    throw PipelineErrorType.invalidCommandType
                }
                return typedResult
            }
        }
        
        // For multiple middleware, use index-based execution
        return try await executeAtIndex(
            0,
            command: command,
            context: context,
            middleware: middleware,
            handler: handler
        )
    }
    
    @inline(__always)
    private func executeAtIndex<T: Command>(
        _ index: Int,
        command: T,
        context: CommandContext,
        middleware: [any Middleware],
        handler: H
    ) async throws -> T.Result {
        let mw = middleware[index]
        
        return try await mw.execute(command, context: context) { cmd, ctx in
            if index + 1 < middleware.count {
                // More middleware to execute
                return try await self.executeAtIndex(
                    index + 1,
                    command: cmd,
                    context: ctx,
                    middleware: middleware,
                    handler: handler
                )
            } else {
                // Last middleware, execute handler
                guard let hCmd = cmd as? H.CommandType else {
                    throw PipelineErrorType.invalidCommandType
                }
                let result = try await handler.handle(hCmd)
                guard let typedResult = result as? T.Result else {
                    throw PipelineErrorType.invalidCommandType
                }
                return typedResult
            }
        }
    }
}

// MARK: - Truly optimized version using function composition
/// An experimental pipeline that pre-builds the execution chain at construction time
public final class TrulyPreCompiledPipeline<H: CommandHandler>: Pipeline {
    private let executionFunc: @Sendable (Any, CommandContext) async throws -> Any
    
    public init(
        handler: H,
        middleware: [any Middleware],
        options: PipelineOptions = PipelineOptions()
    ) {
        // Build the execution function once at construction time
        if middleware.isEmpty {
            self.executionFunc = { command, _ in
                guard let hCmd = command as? H.CommandType else {
                    throw PipelineErrorType.invalidCommandType
                }
                return try await handler.handle(hCmd)
            }
        } else {
            // Build chain in reverse order
            var next: @Sendable (Any, CommandContext) async throws -> Any = { command, _ in
                guard let hCmd = command as? H.CommandType else {
                    throw PipelineErrorType.invalidCommandType
                }
                return try await handler.handle(hCmd)
            }
            
            for mw in middleware.reversed() {
                let currentMw = mw
                let previousNext = next
                next = { command, context in
                    // Create a minimal command wrapper that defers type checking
                    let wrapper = CommandWrapper(
                        base: command,
                        next: previousNext
                    )
                    return try await currentMw.execute(
                        wrapper,
                        context: context,
                        next: { wrappedCmd, ctx in
                            try await wrappedCmd.executeNext(ctx)
                        }
                    )
                }
            }
            
            self.executionFunc = next
        }
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        let result = try await executionFunc(command, context)
        guard let typedResult = result as? T.Result else {
            throw PipelineErrorType.invalidCommandType
        }
        return typedResult
    }
}

// Minimal command wrapper to defer type checking
private struct CommandWrapper<Base>: Command {
    let base: Base
    let next: @Sendable (Any, CommandContext) async throws -> Any
    
    typealias Result = Any
    
    func execute() async throws -> Any {
        fatalError("Should not be called directly")
    }
    
    func executeNext(_ context: CommandContext) async throws -> Any {
        return try await next(base, context)
    }
}