import Foundation
import PipelineKit

/// A middleware that runs a set of ``ObserverMiddleware`` concurrently, then
/// executes the command once.
///
/// Each observer runs in its own child task against the shared `CommandContext`.
/// All observers must complete before the command proceeds; if any observer
/// throws, the siblings are cancelled and the error propagates. Observers do not
/// transform the command or result — they only perform side effects (logging,
/// metrics, validation).
///
/// ## Example
/// ```swift
/// let parallel = ParallelMiddlewareWrapper(observers: [
///     LoggingObserver(),
///     MetricsObserver(),
///     AuditObserver()
/// ])
/// ```
///
/// ## Thread Safety
/// All observers receive the same command and context references. Because
/// `CommandContext` is thread-safe, concurrent access from the observers is safe.
public struct ParallelMiddlewareWrapper: Middleware, Sendable {
    /// The observers to run concurrently.
    private let observers: [any ObserverMiddleware]

    /// The execution priority of the wrapper itself.
    public let priority: ExecutionPriority

    /// Creates a wrapper that runs `observers` in parallel.
    ///
    /// - Parameters:
    ///   - observers: The observers to run concurrently.
    ///   - priority: Execution priority for this wrapper (defaults to `.custom`).
    public init(
        observers: [any ObserverMiddleware],
        priority: ExecutionPriority = .custom
    ) {
        self.observers = observers
        self.priority = priority
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        switch observers.count {
        case 0:
            break
        case 1:
            // Single-observer fast path: skip the task group.
            try await observers[0].observe(command, context: context)
        default:
            try await runObservers(command: command, context: context)
        }
        return try await next(command, context)
    }

    /// Runs all observers concurrently. If any throws, the group cancels the rest
    /// and the first error is rethrown.
    private func runObservers<T: Command>(
        command: T,
        context: CommandContext
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    try await observer.observe(command, context: context)
                }
            }
            try await group.waitForAll()
        }
    }
}
