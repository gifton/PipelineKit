import Foundation
import PipelineKit

/// Actor-based test middleware for thread-safe testing.
///
/// This uses Swift's actor model for thread safety, providing
/// a modern alternative to lock-based synchronization.
///
/// ## Thread Safety
/// - All state is isolated within the actor
/// - Concurrent access is automatically serialized
/// - No risk of data races or deadlocks
///
/// ## Usage
/// ```swift
/// let middleware = ActorTestMiddleware()
/// // Use in concurrent tests
/// await withTaskGroup(of: Void.self) { group in
///     for i in 0..<100 {
///         group.addTask {
///             try await pipeline.execute(command)
///         }
///     }
/// }
/// // Safe to access from any context
/// let count = await middleware.getExecutionCount()
/// XCTAssertEqual(count, 100)
/// ```
public actor ActorTestMiddleware: Middleware {
    private var executionCount = 0
    private var lastCommand: (any Command)?
    private var lastContext: CommandContext?

    public let priority: ExecutionPriority = .custom

    public init() {}

    /// Get current execution count
    public func getExecutionCount() -> Int {
        executionCount
    }

    /// Get last executed command
    public func getLastCommand() -> (any Command)? {
        lastCommand
    }

    /// Get last execution context
    public func getLastContext() -> CommandContext? {
        lastContext
    }

    /// Reset all state
    public func reset() {
        executionCount = 0
        lastCommand = nil
        lastContext = nil
    }

    public nonisolated func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // Update state on actor
        await recordExecution(command, context: context)

        // Execute next
        return try await next(command, context)
    }

    private func recordExecution(_ command: any Command, context: CommandContext) {
        executionCount += 1
        lastCommand = command
        lastContext = context
    }
}
