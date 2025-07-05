import Foundation

/// Protocol for middleware that can optimize for batch processing
public protocol BatchAwareMiddleware: Middleware {
    /// Process multiple commands in a single batch operation
    func executeBatch<T: Command>(
        _ commands: [(command: T, context: CommandContext)],
        batchContext: BatchContext,
        next: @Sendable ([(T, CommandContext)]) async throws -> [T.Result]
    ) async throws -> [T.Result]
}

/// Wrapper to make regular middleware work with batch processing
public struct BatchMiddlewareAdapter: Middleware {
    private let batchAware: any BatchAwareMiddleware
    
    public init(_ middleware: any BatchAwareMiddleware) {
        self.batchAware = middleware
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if this is part of a batch
        if let batchContext = await context.get(BatchContextKey.self) {
            // For now, process as single command within batch context
            // In a full implementation, this would accumulate commands
            let results = try await batchAware.executeBatch(
                [(command, context)],
                batchContext: batchContext,
                next: { commands in
                    try await [next(commands[0].0, commands[0].1)]
                }
            )
            return results[0]
        } else {
            // Process as single command
            let results = try await batchAware.executeBatch(
                [(command, context)],
                batchContext: BatchContext(batchId: 0, size: 1),
                next: { commands in
                    try await [next(commands[0].0, commands[0].1)]
                }
            )
            return results[0]
        }
    }
}

/// Extension to make BatchAwareMiddleware conform to Middleware
public extension BatchAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Default implementation delegates to batch with single item
        let results = try await executeBatch(
            [(command, context)],
            batchContext: BatchContext(batchId: 0, size: 1),
            next: { commands in
                try await [next(commands[0].0, commands[0].1)]
            }
        )
        return results[0]
    }
}