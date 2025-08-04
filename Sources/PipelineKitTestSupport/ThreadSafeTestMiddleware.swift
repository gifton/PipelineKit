import Foundation
import PipelineKit

/// Thread-safe test middleware for concurrent test scenarios.
///
/// Unlike `TestMiddleware`, this implementation uses proper synchronization
/// to ensure thread safety when tracking execution state.
///
/// ## Thread Safety
/// - Uses NSLock for synchronization of mutable state
/// - Safe for concurrent access from multiple threads
/// - Suitable for parallel test execution
///
/// ## Usage
/// ```swift
/// let middleware = ThreadSafeTestMiddleware()
/// // Use in concurrent tests
/// await withTaskGroup(of: Void.self) { group in
///     for i in 0..<100 {
///         group.addTask {
///             try await pipeline.execute(command)
///         }
///     }
/// }
/// // Safe to access from main thread
/// XCTAssertEqual(middleware.executionCount, 100)
/// ```
public final class ThreadSafeTestMiddleware: Middleware, Sendable {
    private let lock = NSLock()
    private var _executionCount = 0
    private var _lastCommand: (any Command)?
    private var _lastContext: CommandContext?
    
    public let priority: ExecutionPriority = .custom
    
    public init() {}
    
    /// Thread-safe access to execution count
    public var executionCount: Int {
        lock.withLock { _executionCount }
    }
    
    /// Thread-safe access to last command
    public var lastCommand: (any Command)? {
        lock.withLock { _lastCommand }
    }
    
    /// Thread-safe access to last context
    public var lastContext: CommandContext? {
        lock.withLock { _lastContext }
    }
    
    /// Reset all tracked state
    public func reset() {
        lock.withLock {
            _executionCount = 0
            _lastCommand = nil
            _lastContext = nil
        }
    }
    
    /// Get a snapshot of current state
    public func getSnapshot() -> (count: Int, command: (any Command)?, context: CommandContext?) {
        lock.withLock {
            (_executionCount, _lastCommand, _lastContext)
        }
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Update state with lock
        lock.withLock {
            _executionCount += 1
            _lastCommand = command
            _lastContext = context
        }
        
        // Execute next (outside lock to avoid deadlocks)
        return try await next(command, context)
    }
}

/// Thread-safe test middleware that tracks execution history.
///
/// This middleware maintains a history of all executed commands,
/// suitable for tests that need to verify execution order.
public final class ThreadSafeHistoryMiddleware: Middleware, Sendable {
    private let lock = NSLock()
    private var _history: [(command: any Command, context: CommandContext, timestamp: Date)] = []
    
    public let priority: ExecutionPriority = .custom
    
    public init() {}
    
    /// Thread-safe access to execution history
    public var history: [(command: any Command, context: CommandContext, timestamp: Date)] {
        lock.withLock { _history }
    }
    
    /// Thread-safe access to execution count
    public var executionCount: Int {
        lock.withLock { _history.count }
    }
    
    /// Get commands of a specific type from history
    public func commands<T: Command>(of type: T.Type) -> [T] {
        lock.withLock {
            _history.compactMap { $0.command as? T }
        }
    }
    
    /// Clear history
    public func reset() {
        lock.withLock {
            _history.removeAll()
        }
    }
    
    /// Check if a command type was executed
    public func wasExecuted<T: Command>(_ type: T.Type) -> Bool {
        lock.withLock {
            _history.contains { $0.command is T }
        }
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Record execution
        lock.withLock {
            _history.append((command: command, context: context, timestamp: Date()))
        }
        
        return try await next(command, context)
    }
}

/// Actor-based test middleware as an alternative approach.
///
/// This uses Swift's actor model for thread safety instead of locks.
/// Suitable when async access patterns are acceptable in tests.
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
        next: @Sendable (T, CommandContext) async throws -> T.Result
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