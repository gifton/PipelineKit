import Foundation
import PipelineKitCore

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
    
    public func handle(_ command: MockCommand) async throws -> String {
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
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple authentication check
        guard context.commandMetadata.userId != nil else {
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
        next: @Sendable (T, CommandContext) async throws -> T.Result
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

/// ## Design Decision: @unchecked Sendable for Test Mock with Mutable State
///
/// This test mock uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Test Observation Pattern**: Test mocks need mutable arrays to record
///    interactions for test assertions. This is a fundamental testing pattern.
///
/// 2. **Alternative Considered**: Using an actor would require async access to
///    check logged commands, complicating test assertions unnecessarily.
///
/// 3. **Thread Safety:** All access to the mutable array is protected
///    by NSLock, ensuring thread-safe access from concurrent test executions.
///
/// 4. **Thread Safety Invariant:** All mutations to the loggedCommands array
///    MUST be performed within lock.withLock { } blocks. Direct access outside
///    of lock protection will cause data races.
///
/// This is a permanent solution for test infrastructure where synchronous
/// access to test data is required for assertions.
public final class MockLoggingMiddleware: Middleware, @unchecked Sendable {
    public let priority = ExecutionPriority.postProcessing
    public private(set) var loggedCommands: [String] = []
    private let lock = NSLock()
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandName = String(describing: type(of: command))
        lock.withLock {
            loggedCommands.append(commandName)
        }
        return try await next(command, context)
    }
}

/// ## Design Decision: @unchecked Sendable for Test Mock with Metrics Collection
///
/// This test mock uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Metrics Recording Pattern**: Test mocks need to collect timing metrics
///    in a mutable array for performance assertions in tests.
///
/// 2. **Alternative Considered**: Actor-based design would require async access
///    patterns that complicate test assertions and metric analysis.
///
/// 3. **Thread Safety:** NSLock protects all access to the metrics
///    array, preventing data races during concurrent middleware execution.
///
/// 4. **Thread Safety Invariant:** All access to the recordedMetrics array
///    MUST occur within lock.withLock { } blocks. The array must never be
///    accessed or modified outside of lock protection.
///
/// This is a permanent solution for test infrastructure requiring synchronous
/// access to collected metrics for validation.
public final class MockMetricsMiddleware: Middleware, @unchecked Sendable {
    public let priority = ExecutionPriority.postProcessing
    public private(set) var recordedMetrics: [(command: String, duration: TimeInterval)] = []
    private let lock = NSLock()
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let duration = Date().timeIntervalSince(start)
        
        let commandName = String(describing: type(of: command))
        lock.withLock {
            recordedMetrics.append((command: commandName, duration: duration))
        }
        
        return result
    }
}
