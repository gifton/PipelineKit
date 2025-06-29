import Foundation

/// Middleware provides cross-cutting functionality in the command pipeline.
public protocol Middleware: Sendable {
    /// The priority of the middleware, which determines its execution order.
    var priority: ExecutionPriority { get }

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

// Add extension for default priority
public extension Middleware {
    var priority: ExecutionPriority { .custom }
}
