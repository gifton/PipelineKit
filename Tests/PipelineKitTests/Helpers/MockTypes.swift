import Foundation
@testable import PipelineKit

// MARK: - Mock Command

struct MockCommand: Command {
    typealias Result = String
    
    let value: Int
    let shouldFail: Bool
    
    init(value: Int = 42, shouldFail: Bool = false) {
        self.value = value
        self.shouldFail = shouldFail
    }
}

// MARK: - Mock Command Handler

final class MockCommandHandler: CommandHandler {
    typealias CommandType = MockCommand
    
    func handle(_ command: MockCommand) async throws -> String {
        if command.shouldFail {
            throw TestError.commandFailed
        }
        return "Result: \(command.value)"
    }
}

// MARK: - Mock Middleware

final class MockAuthenticationMiddleware: Middleware, @unchecked Sendable {
    let priority = ExecutionPriority.authentication
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple authentication check
        guard context.commandMetadata.userId != nil else {
            throw TestError.unauthorized
        }
        return try await next(command, context)
    }
}

final class MockValidationMiddleware: Middleware, @unchecked Sendable {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple validation
        if let mockCommand = command as? MockCommand {
            guard mockCommand.value >= 0 else {
                throw TestError.validationFailed
            }
        }
        return try await next(command, context)
    }
}

final class MockLoggingMiddleware: Middleware, @unchecked Sendable {
    let priority = ExecutionPriority.postProcessing
    private(set) var loggedCommands: [String] = []
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandName = String(describing: type(of: command))
        loggedCommands.append(commandName)
        return try await next(command, context)
    }
}

final class MockMetricsMiddleware: Middleware, @unchecked Sendable {
    let priority = ExecutionPriority.postProcessing
    private(set) var recordedMetrics: [(command: String, duration: TimeInterval)] = []
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = Date()
        let result = try await next(command, context)
        let duration = Date().timeIntervalSince(start)
        
        let commandName = String(describing: type(of: command))
        recordedMetrics.append((command: commandName, duration: duration))
        
        return result
    }
}