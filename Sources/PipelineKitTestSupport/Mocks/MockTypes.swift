import Foundation
import PipelineKit

// MARK: - Mock Command

public struct MockCommand: Command {
    public typealias Result = String
    
    public let value: Int
    public let shouldFail: Bool
    
    public init(value: Int = 42, shouldFail: Bool = false) {
        self.value = value
        self.shouldFail = shouldFail
    }
}

// MARK: - Mock Command Handler

public final class MockCommandHandler: CommandHandler {
    public typealias CommandType = MockCommand

    public init() {}

    public func handle(_ command: MockCommand, context: CommandContext) async throws -> String {
        if command.shouldFail {
            throw PipelineError.executionFailed(message: "Command failed", context: nil)
        }
        return "Result: \(command.value)"
    }
}

// MARK: - Mock Middleware

public final class MockAuthenticationMiddleware: Middleware, Sendable {
    public let priority = ExecutionPriority.authentication
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple authentication check
        guard context.commandMetadata.userID != nil else {
            throw PipelineError.authorization(reason: .invalidCredentials)
        }
        return try await next(command, context)
    }
}

public final class MockValidationMiddleware: Middleware, Sendable {
    public let priority = ExecutionPriority.validation
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple validation
        if let mockCommand = command as? MockCommand {
            guard mockCommand.value >= 0 else {
                throw PipelineError.validation(field: "value", reason: .custom("Value must be non-negative"))
            }
        }
        return try await next(command, context)
    }
}

/// Records command names using the same lock for writes and snapshot reads.
/// `MockSnapshotContractTests.testConcurrentMockWritersAndSnapshotReaders` exercises
/// concurrent readers and writers for both recording middleware types.
public final class MockLoggingMiddleware: Middleware, @unchecked Sendable {
    public let priority = ExecutionPriority.postProcessing
    private var loggedCommandsStorage: [String] = []
    public var loggedCommands: [String] {
        lock.withLock { loggedCommandsStorage }
    }
    private let lock = NSLock()
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandName = String(describing: type(of: command))
        lock.withLock {
            loggedCommandsStorage.append(commandName)
        }
        return try await next(command, context)
    }
}

/// Records timing metrics using the same lock for writes and snapshot reads.
/// Concurrent access is exercised by
/// `MockSnapshotContractTests.testConcurrentMockWritersAndSnapshotReaders`.
public final class MockMetricsMiddleware: Middleware, @unchecked Sendable {
    public let priority = ExecutionPriority.postProcessing
    private var recordedMetricsStorage: [(command: String, duration: TimeInterval)] = []
    public var recordedMetrics: [(command: String, duration: TimeInterval)] {
        lock.withLock { recordedMetricsStorage }
    }
    private let lock = NSLock()
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let duration = Date().timeIntervalSince(start)
        
        let commandName = String(describing: type(of: command))
        lock.withLock {
            recordedMetricsStorage.append((command: commandName, duration: duration))
        }
        
        return result
    }
}
