//
//  MockMiddlewareFactory.swift
//  PipelineKit
//
//  Factory methods for creating mock middleware in tests.
//

import Foundation
import PipelineKit

// MARK: - Mock Middleware Factory

/// Factory for creating pre-configured mock middleware for testing.
///
/// ## Usage
///
/// ```swift
/// // Create a logging middleware that captures all commands
/// let logger = MockMiddlewareFactory.logger()
/// pipeline.use(logger)
///
/// // Execute command
/// let result = try await pipeline.execute(MyCommand())
///
/// // Assert on captured data
/// XCTAssertEqual(logger.executedCommands.count, 1)
/// ```
public enum MockMiddlewareFactory {

    // MARK: - Logging Middleware

    /// Creates a thread-safe logging middleware that captures execution details.
    ///
    /// - Returns: A `CapturingMiddleware` that records all command executions.
    public static func logger() -> CapturingMiddleware {
        CapturingMiddleware()
    }

    // MARK: - Delay Middleware

    /// Creates middleware that introduces a delay before passing to next.
    ///
    /// - Parameter delay: The delay in seconds.
    /// - Returns: A middleware that delays execution.
    public static func delay(_ delay: TimeInterval) -> DelayMiddleware {
        DelayMiddleware(delay: delay)
    }

    // MARK: - Failing Middleware

    /// Creates middleware that always throws an error.
    ///
    /// - Parameter error: The error to throw. Defaults to `TestError.middlewareFailed`.
    /// - Returns: A middleware that always fails.
    public static func failing(with error: any Error = TestError.middlewareFailed) -> TestFailingMiddleware {
        TestFailingMiddleware(error: error)
    }

    // MARK: - Conditional Middleware

    /// Creates middleware that fails on specific conditions.
    ///
    /// - Parameter predicate: A predicate that returns true when the middleware should fail.
    /// - Returns: A middleware that conditionally fails.
    public static func failingWhen(
        _ predicate: @escaping @Sendable (any Command, CommandContext) -> Bool
    ) -> ConditionalFailingMiddleware {
        ConditionalFailingMiddleware(shouldFail: predicate)
    }

    // MARK: - Counter Middleware

    /// Creates middleware that counts executions.
    ///
    /// - Returns: A `CountingMiddleware` that tracks execution count.
    public static func counter() -> CountingMiddleware {
        CountingMiddleware()
    }

    // MARK: - Modifier Middleware

    /// Creates middleware that modifies the context before execution.
    ///
    /// - Parameter modifier: A closure that modifies the context.
    /// - Returns: A middleware that applies the modification.
    public static func modifying(
        _ modifier: @escaping @Sendable (CommandContext) -> Void
    ) -> ContextModifyingMiddleware {
        ContextModifyingMiddleware(modifier: modifier)
    }

    // MARK: - Timeout Simulation

    /// Creates middleware that simulates a timeout by delaying longer than expected.
    ///
    /// - Parameter duration: The delay duration (should exceed test timeout).
    /// - Returns: A middleware that simulates timeout conditions.
    public static func simulatingTimeout(duration: TimeInterval = 60) -> DelayMiddleware {
        DelayMiddleware(delay: duration)
    }
}

// MARK: - Capturing Middleware

/// Thread-safe middleware that captures all execution details for testing.
public final class CapturingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .custom

    private let lock = NSLock()
    private var _executedCommands: [CommandRecord] = []
    private var _contexts: [CommandContext] = []

    public init() {}

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    /// Records of all executed commands.
    public var executedCommands: [CommandRecord] {
        withLock { _executedCommands }
    }

    /// All contexts passed to this middleware.
    public var contexts: [CommandContext] {
        withLock { _contexts }
    }

    /// Number of times execute was called.
    public var executionCount: Int {
        withLock { _executedCommands.count }
    }

    /// Resets all captured data.
    public func reset() {
        withLock {
            _executedCommands.removeAll()
            _contexts.removeAll()
        }
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let record = CommandRecord(
            commandType: String(describing: T.self),
            timestamp: Date()
        )

        withLock {
            _executedCommands.append(record)
            _contexts.append(context)
        }

        return try await next(command, context)
    }

    /// Record of a single command execution.
    public struct CommandRecord: Sendable {
        public let commandType: String
        public let timestamp: Date
    }
}

// MARK: - Delay Middleware

/// Middleware that introduces a configurable delay.
public struct DelayMiddleware: Middleware, Sendable {
    public let priority: ExecutionPriority = .custom
    public let delay: TimeInterval

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return try await next(command, context)
    }
}

// MARK: - Conditional Failing Middleware

/// Middleware that fails based on a condition.
public struct ConditionalFailingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .custom
    private let shouldFail: @Sendable (any Command, CommandContext) -> Bool

    public init(shouldFail: @escaping @Sendable (any Command, CommandContext) -> Bool) {
        self.shouldFail = shouldFail
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        if shouldFail(command, context) {
            throw TestError.middlewareFailed
        }
        return try await next(command, context)
    }
}

// MARK: - Counting Middleware

/// Thread-safe middleware that counts executions.
public final class CountingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .custom

    private let lock = NSLock()
    private var _count: Int = 0

    public init() {}

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    /// Current execution count.
    public var count: Int {
        withLock { _count }
    }

    /// Resets the counter to zero.
    public func reset() {
        withLock { _count = 0 }
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        withLock { _count += 1 }
        return try await next(command, context)
    }
}

// MARK: - Context Modifying Middleware

/// Middleware that modifies the context before execution.
public struct ContextModifyingMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .preProcessing
    private let modifier: @Sendable (CommandContext) -> Void

    public init(modifier: @escaping @Sendable (CommandContext) -> Void) {
        self.modifier = modifier
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        modifier(context)
        return try await next(command, context)
    }
}
