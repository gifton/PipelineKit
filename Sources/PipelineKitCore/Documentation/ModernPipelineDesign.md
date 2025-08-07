import Foundation

// MARK: - Core Protocol

/// Commands represent units of work that produce a result
public protocol Command: Sendable {
    associatedtype Output: Sendable
    
    /// The actual business logic lives here
    func handle() async throws -> Output
}

// MARK: - Pipeline Stage

/// A stage is a function that wraps command execution
public typealias Stage = @Sendable (
    _ command: any Command,
    _ next: @escaping @Sendable (any Command) async throws -> Any
) async throws -> Any

// MARK: - Pipeline Builder

/// Result builder for composing pipeline stages
@resultBuilder
public enum PipelineBuilder {
    public static func buildBlock(_ stages: Stage...) -> [Stage] {
        stages
    }
    
    public static func buildArray(_ stages: [[Stage]]) -> [Stage] {
        stages.flatMap { $0 }
    }
    
    public static func buildOptional(_ stages: [Stage]?) -> [Stage] {
        stages ?? []
    }
    
    public static func buildEither(first stages: [Stage]) -> [Stage] {
        stages
    }
    
    public static func buildEither(second stages: [Stage]) -> [Stage] {
        stages
    }
}

// MARK: - Pipeline

/// A type-safe pipeline that executes commands through a series of stages
public struct Pipeline<C: Command>: Sendable {
    private let stages: [Stage]
    
    public init(@PipelineBuilder _ builder: () -> [Stage]) {
        self.stages = builder()
    }
    
    /// Execute a command through the pipeline
    public func run(_ command: C) async throws -> C.Output {
        let result = try await Self.executeStages(stages, command: command)
        
        // Type-safe cast back to expected output
        guard let typedResult = result as? C.Output else {
            throw PipelineError.typeMismatch(
                expected: String(describing: C.Output.self),
                actual: String(describing: type(of: result))
            )
        }
        
        return typedResult
    }
    
    /// Recursive execution through stages
    private static func executeStages(
        _ remainingStages: [Stage],
        command: any Command
    ) async throws -> Any {
        guard let currentStage = remainingStages.first else {
            // No more stages, execute the command
            return try await command.handle()
        }
        
        // Execute current stage with next as the continuation
        return try await currentStage(command) { nextCommand in
            try await executeStages(
                Array(remainingStages.dropFirst()),
                command: nextCommand
            )
        }
    }
}

// MARK: - Stage Helpers

/// Timeout stage - enforces time limits on command execution
public func timeout(
    _ duration: Duration,
    clock: any Clock<Duration> = ContinuousClock()
) -> Stage {
    return { command, next in
        try await withThrowingTimeout(on: clock, for: duration) {
            try await next(command)
        }
    }
}

/// Alternative timeout with TimeInterval for compatibility
public func timeout(seconds: TimeInterval) -> Stage {
    return timeout(.seconds(Int64(seconds)))
}

/// Metrics recording stage
public func recordMetrics(label: String) -> Stage {
    return { command, next in
        let start = ContinuousClock.now
        let commandType = String(describing: type(of: command))
        
        do {
            let result = try await next(command)
            let duration = ContinuousClock.now - start
            
            // Record success metrics
            await MetricsCollector.shared.record(
                label: label,
                commandType: commandType,
                duration: duration,
                success: true
            )
            
            return result
        } catch {
            let duration = ContinuousClock.now - start
            
            // Record failure metrics
            await MetricsCollector.shared.record(
                label: label,
                commandType: commandType,
                duration: duration,
                success: false,
                error: error
            )
            
            throw error
        }
    }
}

/// Retry stage with exponential backoff
public func retry(
    maxAttempts: Int = 3,
    backoff: Duration = .seconds(1)
) -> Stage {
    return { command, next in
        var lastError: Error?
        var currentBackoff = backoff
        
        for attempt in 1...maxAttempts {
            do {
                return try await next(command)
            } catch {
                lastError = error
                
                // Don't sleep after the last attempt
                if attempt < maxAttempts {
                    try await Task.sleep(for: currentBackoff)
                    currentBackoff = currentBackoff * 2 // Exponential backoff
                }
            }
        }
        
        throw lastError ?? PipelineError.unknownError
    }
}

/// Circuit breaker stage
public func circuitBreaker(
    failureThreshold: Int = 5,
    resetTimeout: Duration = .seconds(60)
) -> Stage {
    let breaker = CircuitBreakerActor(
        threshold: failureThreshold,
        resetTimeout: resetTimeout
    )
    
    return { command, next in
        guard await breaker.allowRequest() else {
            throw PipelineError.circuitBreakerOpen
        }
        
        do {
            let result = try await next(command)
            await breaker.recordSuccess()
            return result
        } catch {
            await breaker.recordFailure()
            throw error
        }
    }
}

// MARK: - TaskLocal Context

/// Request context that flows through the pipeline
public struct RequestContext: Sendable {
    public let requestId: UUID
    public let userId: String?
    public let deadline: ContinuousClock.Instant?
    public let traceId: String?
    public let metadata: [String: String]
    
    public init(
        requestId: UUID = UUID(),
        userId: String? = nil,
        deadline: ContinuousClock.Instant? = nil,
        traceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.requestId = requestId
        self.userId = userId
        self.deadline = deadline
        self.traceId = traceId
        self.metadata = metadata
    }
}

extension TaskLocal where Value == RequestContext? {
    public static let current = TaskLocal<RequestContext?>()
}

/// Stage that injects request context
public func withContext(_ context: RequestContext) -> Stage {
    return { command, next in
        try await TaskLocal.current.withValue(context) {
            try await next(command)
        }
    }
}

/// Stage that enforces deadline from context
public func enforceDeadline() -> Stage {
    return { command, next in
        guard let context = TaskLocal.current.get(),
              let deadline = context.deadline else {
            // No deadline, proceed normally
            return try await next(command)
        }
        
        let now = ContinuousClock.now
        guard deadline > now else {
            throw PipelineError.deadlineExceeded
        }
        
        let remaining = deadline - now
        return try await withThrowingTimeout(for: remaining) {
            try await next(command)
        }
    }
}

// MARK: - Logging Stage

public func log(level: LogLevel = .info) -> Stage {
    return { command, next in
        let commandType = String(describing: type(of: command))
        let context = TaskLocal.current.get()
        
        Logger.log(
            level: level,
            message: "Executing command: \(commandType)",
            requestId: context?.requestId,
            traceId: context?.traceId
        )
        
        do {
            let result = try await next(command)
            
            Logger.log(
                level: level,
                message: "Command succeeded: \(commandType)",
                requestId: context?.requestId,
                traceId: context?.traceId
            )
            
            return result
        } catch {
            Logger.log(
                level: .error,
                message: "Command failed: \(commandType)",
                error: error,
                requestId: context?.requestId,
                traceId: context?.traceId
            )
            
            throw error
        }
    }
}

// MARK: - Example Usage

struct FetchUserCommand: Command {
    let userId: String
    
    func handle() async throws -> User {
        // Simulate database fetch
        try await Task.sleep(for: .milliseconds(100))
        return User(id: userId, name: "John Doe")
    }
}

struct User: Sendable {
    let id: String
    let name: String
}

// Create a pipeline with multiple stages
let userPipeline = Pipeline<FetchUserCommand> {
    // Inject request context
    withContext(RequestContext(
        userId: "current-user",
        deadline: ContinuousClock.now + .seconds(5)
    ))
    
    // Logging
    log(level: .info)
    
    // Metrics
    recordMetrics(label: "user.fetch")
    
    // Circuit breaker
    circuitBreaker(failureThreshold: 10)
    
    // Retry with backoff
    retry(maxAttempts: 3)
    
    // Timeout enforcement
    timeout(seconds: 2)
    
    // Deadline from context
    enforceDeadline()
}

// Usage
func example() async throws {
    let command = FetchUserCommand(userId: "123")
    let user = try await userPipeline.run(command)
    print("Fetched user: \(user.name)")
}

// MARK: - Supporting Types

enum PipelineError: Error {
    case typeMismatch(expected: String, actual: String)
    case circuitBreakerOpen
    case deadlineExceeded
    case unknownError
}

enum LogLevel {
    case debug, info, warning, error
}

// Mock implementations
actor MetricsCollector {
    static let shared = MetricsCollector()
    
    func record(
        label: String,
        commandType: String,
        duration: Duration,
        success: Bool,
        error: Error? = nil
    ) async {
        // Record metrics
    }
}

actor CircuitBreakerActor {
    private var failureCount = 0
    private var isOpen = false
    private let threshold: Int
    private let resetTimeout: Duration
    
    init(threshold: Int, resetTimeout: Duration) {
        self.threshold = threshold
        self.resetTimeout = resetTimeout
    }
    
    func allowRequest() async -> Bool {
        return !isOpen
    }
    
    func recordSuccess() async {
        failureCount = 0
    }
    
    func recordFailure() async {
        failureCount += 1
        if failureCount >= threshold {
            isOpen = true
            // Schedule reset
            Task {
                try await Task.sleep(for: resetTimeout)
                await self.reset()
            }
        }
    }
    
    private func reset() {
        isOpen = false
        failureCount = 0
    }
}

struct Logger {
    static func log(
        level: LogLevel,
        message: String,
        error: Error? = nil,
        requestId: UUID? = nil,
        traceId: String? = nil
    ) {
        // Log implementation
    }
}

// MARK: - Distributed Extension

import Distributed

/// Distributed actor for remote command execution
distributed actor CommandGateway {
    typealias ActorSystem = LocalTestingDistributedActorSystem
    
    distributed func execute<C: Command & Codable>(
        _ command: C
    ) async throws -> C.Output where C.Output: Codable {
        // In a real implementation, this would look up the appropriate pipeline
        // For now, just execute directly
        return try await command.handle()
    }
}

// MARK: - Advanced Composition

/// Conditional stage execution
public func when(
    _ condition: @escaping (any Command) -> Bool,
    @PipelineBuilder then stages: () -> [Stage]
) -> Stage {
    let conditionalStages = stages()
    
    return { command, next in
        if condition(command) {
            // Execute conditional stages then continue
            return try await Pipeline<DynamicCommand>.executeStages(
                conditionalStages + [{ cmd, _ in try await next(cmd) }],
                command: command
            )
        } else {
            // Skip conditional stages
            return try await next(command)
        }
    }
}

/// Dynamic command wrapper for conditional execution
private struct DynamicCommand: Command {
    let wrapped: any Command
    
    func handle() async throws -> Any {
        try await wrapped.handle()
    }
}

// Example with conditional stage
let advancedPipeline = Pipeline<FetchUserCommand> {
    log()
    
    // Only apply timeout for non-admin users
    when({ _ in TaskLocal.current.get()?.userId != "admin" }) {
        timeout(seconds: 5)
    }
    
    recordMetrics(label: "user.fetch")
}