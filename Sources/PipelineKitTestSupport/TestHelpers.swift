//
//  TestHelpers.swift
//  PipelineKit
//
//  Test utilities for context-based testing
//

import Foundation
import PipelineKit

// MARK: - Test Errors

/// Common errors used in tests
public enum TestError: Error, LocalizedError {
    case commandFailed
    case unauthorized
    case validationFailed
    case timeout
    case middlewareFailed
    case pipelineFailed
    case rateLimitExceeded
    case customError(String)
    
    public var errorDescription: String? {
        switch self {
        case .commandFailed:
            return "Command failed"
        case .unauthorized:
            return "Unauthorized"
        case .validationFailed:
            return "Validation failed"
        case .timeout:
            return "Operation timed out"
        case .middlewareFailed:
            return "Middleware failed"
        case .pipelineFailed:
            return "Pipeline failed"
        case .rateLimitExceeded:
            return "Rate limit exceeded"
        case .customError(let message):
            return message
        }
    }
}

// MARK: - Test Actor for Thread-Safe Collection

/// Helper actor for thread-safe test data collection
public actor TestActor <T: Sendable> {
    private var value: T
    
    public init(_ value: T) {
        self.value = value
    }
    
    public func get() -> T {
        value
    }
    
    public func set(_ newValue: T) {
        value = newValue
    }
    
    public func increment() where T == Int {
        value += 1
    }
    
    public func incrementCount(for key: String) where T == [String: Int] {
        value[key, default: 0] += 1
    }
    
    public func append<Element>(_ element: Element) where T == [Element] {
        value.append(element)
    }
}

// MARK: - Test Command Metadata

/// ## Design Decision: @unchecked Sendable for Test Metadata with Any Values
///
/// This test type uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Any Type Storage**: The `additionalData: [String: Any]` property uses
///    the Any type which cannot be verified as Sendable by the compiler.
///
/// 2. **Alternative Considered**: Using a typed enum for values would limit
///    test flexibility and require constant updates for new test scenarios.
///
/// 3. **Thread Safety:** In test scenarios, this dictionary typically
///    contains simple values (strings, numbers) that are thread-safe. The struct
///    is immutable after creation.
///
/// 4. **Thread Safety Invariant:** All values stored in additionalData MUST be
///    value types (String, Int, Double, etc.) or immutable reference types.
///    Mutable reference types will cause data races.
///
/// This is a permanent solution for test infrastructure requiring flexible
/// metadata storage across diverse test cases.
public struct TestCommandMetadata: CommandMetadata, @unchecked Sendable {
    public let id: UUID
    public let userId: String?
    public let correlationId: String?
    public let timestamp: Date
    public let additionalData: [String: Any]
    
    public init(
        id: UUID = UUID(),
        userId: String? = "test-user",
        correlationId: String? = UUID().uuidString,
        timestamp: Date = Date(),
        additionalData: [String: Any] = [:]
    ) {
        self.id = id
        self.userId = userId
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.additionalData = additionalData
    }
}

// MARK: - CommandContext Test Extensions

// MARK: - Test Context Keys
// Context keys have been replaced with string keys in the new API

public extension CommandContext {
    static func test(
        userId: String? = "test-user",
        correlationId: String = UUID().uuidString,
        additionalData: [String: Any] = [:],
        customKeys: [String: Any] = [:]
    ) -> CommandContext {
        let metadata = TestCommandMetadata(
            userId: userId,
            correlationId: correlationId,
            additionalData: additionalData
        )
        
        let context = CommandContext(metadata: metadata)
        
        // Custom keys would need to be set with proper ContextKey types
        
        return context
    }
    
}

// MARK: - Test Commands

public struct TestCommand: Command {
    public typealias Result = String
    
    public let value: String
    public let shouldFail: Bool
    
    public init(value: String = "test", shouldFail: Bool = false) {
        self.value = value
        self.shouldFail = shouldFail
    }
    
    public func execute() async throws -> String {
        if shouldFail {
            throw TestError.commandFailed
        }
        return value
    }
}

public struct AsyncTestCommand: Command {
    public typealias Result = Int
    
    public let delay: TimeInterval
    public let value: Int
    
    public init(delay: TimeInterval = 0.1, value: Int = 42) {
        self.delay = delay
        self.value = value
    }
    
    public func execute() async throws -> Int {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return value
    }
}

// MARK: - Test Middleware

/// ## Design Decision: @unchecked Sendable for Test Observation Middleware
///
/// This test middleware uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Test State Tracking**: Test middleware needs to track execution count
///    and last command/context for test assertions. This requires mutable state.
///
/// 2. **Alternative Considered**: Converting to an actor would require async
///    access to check execution state, complicating test assertions.
///
/// 3. **Thread Safety:** While this implementation doesn't use locks,
///    it's designed for single-threaded test scenarios where middleware execution
///    is typically sequential within a test case.
///
/// 4. **Thread Safety Invariant:** This middleware is ONLY safe for single-threaded
///    test scenarios. For concurrent tests, data races WILL occur. Use thread-safe
///    alternatives like MockLoggingMiddleware for concurrent testing.
///
/// 5. **Usage Constraint**: Test cases using this middleware MUST NOT execute
///    commands concurrently or access properties from multiple threads.
///
/// This is a permanent solution for simple test scenarios. For concurrent tests,
/// use ActorTestMiddleware which provides proper thread safety through actor isolation.
public final class TestMiddleware: Middleware, @unchecked Sendable {
    public var executionCount = 0
    public var lastCommand: (any Command)?
    public var lastContext: CommandContext?
    public let priority: ExecutionPriority = .custom
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        executionCount += 1
        lastCommand = command
        lastContext = context
        
        return try await next(command, context)
    }
}

/// ## Design Decision: @unchecked Sendable for Error-Throwing Test Middleware
///
/// This test middleware uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Error Storage**: The stored `error: Error` property is an existential
///    type that may not be Sendable, preventing automatic Sendable conformance.
///
/// 2. **Thread Safety Guarantee**: The error is immutable after initialization
///    and only read during execution, making it thread-safe in practice.
///
/// 3. **Alternative Considered**: Constraining to Sendable errors would limit
///    test scenarios where custom non-Sendable errors need to be tested.
///
/// 4. **Thread Safety Invariant**: The stored error MUST be immutable after
///    initialization. The error property is never modified after init.
///
/// 5. **Usage Pattern**: Safe for concurrent use as the error is read-only
///    and the middleware itself has no mutable state.
///
/// This is a permanent solution for test infrastructure that needs to simulate
/// various error conditions with different error types.
public final class TestFailingMiddleware: Middleware, @unchecked Sendable {
    public let error: Error
    public let priority: ExecutionPriority = .custom
    
    public init(error: Error = TestError.middlewareFailed) {
        self.error = error
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        throw error
    }
}

/// ## Design Decision: @unchecked Sendable for Generic Context-Modifying Middleware
///
/// This test middleware uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Generic Value Storage**: The stored `value: Key.Value` is constrained
///    only by the ContextKey protocol, not by Sendable, preventing automatic
///    Sendable inference.
///
/// 2. **Thread Safety Guarantee**: The value is immutable after initialization
///    and only used to set context values, which are themselves thread-safe.
///
/// 3. **Alternative Considered**: Adding Sendable constraint to Key.Value would
///    break existing tests and limit flexibility of context values in tests.
///
/// 4. **Thread Safety Invariant**: The stored value MUST be either:
///    - A value type (struct/enum) with Sendable semantics
///    - An immutable reference type
///    - A type that's only accessed through CommandContext's thread-safe API
///
/// 5. **Context Safety**: CommandContext handles thread safety internally,
///    so setting values through context.set() is always safe.
///


// MARK: - Test Utilities

public enum TestConstants {
    public static let defaultUserId = "test-user-123"
    public static let defaultCorrelationId = "test-correlation-123"
    public static let defaultTimeout: TimeInterval = 5.0
}

public extension CommandContext {
    func assertHasMetadata() throws -> CommandMetadata {
        return self.commandMetadata
    }
    
    // Metrics assertion would need proper ContextKey
}

// MARK: - Observability Support

/// Protocol for commands that want to participate in observability events
public protocol ObservableCommand: Command {
    func setupObservability(context: CommandContext) async
    func observabilityDidComplete<Result>(context: CommandContext, result: Result) async
    func observabilityDidFail(context: CommandContext, error: Error) async
}

// MARK: - Retry Support

/// Strategy for calculating retry delays
public enum RetryStrategy: Sendable {
    case immediate
    case fixedDelay(TimeInterval)
    case exponentialBackoff(base: TimeInterval, multiplier: Double, maxDelay: TimeInterval)
    case linearBackoff(base: TimeInterval, increment: TimeInterval, maxDelay: TimeInterval)
    
    /// Calculate the delay for a given retry attempt
    public func delay(for attempt: Int) async -> TimeInterval {
        switch self {
        case .immediate:
            return 0
        case .fixedDelay(let delay):
            return delay
        case let .exponentialBackoff(base, multiplier, maxDelay):
            let delay = base * pow(multiplier, Double(attempt))
            return min(delay, maxDelay)
        case let .linearBackoff(base, increment, maxDelay):
            let delay = base + (increment * Double(attempt))
            return min(delay, maxDelay)
        }
    }
}

// MARK: - Performance Types

/// Performance profiling information for middleware execution
public struct ProfileInfo: Sendable {
    public let executionCount: Int
    public let totalDuration: TimeInterval
    public let averageDuration: TimeInterval
    public let minDuration: TimeInterval
    public let maxDuration: TimeInterval
    
    public init(
        executionCount: Int,
        totalDuration: TimeInterval,
        averageDuration: TimeInterval,
        minDuration: TimeInterval,
        maxDuration: TimeInterval
    ) {
        self.executionCount = executionCount
        self.totalDuration = totalDuration
        self.averageDuration = averageDuration
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }
}

// MARK: - Mock Services

/// ## Design Decision: @unchecked Sendable for Mock Metrics Collector
///
/// This test mock uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Metrics Collection Pattern**: Test mocks need mutable arrays to collect
///    metrics for test verification. This is essential for testing metrics flow.
///
/// 2. **Thread Safety Guarantee**: While this basic implementation doesn't use
///    locks, it's designed for single-threaded test scenarios. For concurrent
///    tests, synchronization should be added.
///
/// 3. **Alternative Considered**: Actor-based design would require async access
///    to recorded metrics, complicating test assertions and metric verification.
///
/// 4. **Thread Safety Invariant**: This mock is NOT thread-safe. Concurrent
///    access to recordedMetrics array will cause data races and crashes.
///
/// 5. **Usage Constraint**: Only use in single-threaded test scenarios OR
///    ensure all access is synchronized externally.
///
/// This is a permanent solution for test infrastructure. Production code should
/// use proper thread-safe metrics collectors.
public final class MockMetricsCollector: @unchecked Sendable {
    public private(set) var recordedMetrics: [(name: String, value: Double, tags: [String: String])] = []
    
    public init() {}
    
    public func record(metric: String, value: Double, tags: [String: String]) {
        recordedMetrics.append((name: metric, value: value, tags: tags))
    }
    
    public func increment(metric: String, tags: [String: String]) {
        record(metric: metric, value: 1.0, tags: tags)
    }
    
    public func timing(metric: String, duration: TimeInterval, tags: [String: String]) {
        record(metric: metric, value: duration, tags: tags)
    }
}

/// ## Design Decision: @unchecked Sendable for Mock Encryption Service
///
/// This test mock uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Stateless Mock**: This mock encryption service has no state and only
///    provides simple transformations for testing, making it inherently thread-safe.
///
/// 2. **Swift Limitation**: Empty classes without stored properties should be
///    automatically Sendable, but Swift sometimes requires explicit marking.
///
/// 3. **Alternative Considered**: Making this a struct would work but classes
///    are more flexible for test mocking with inheritance.
///
/// 4. **Thread Safety Invariant**: This class has NO mutable state. All methods
///    are pure functions that don't access or modify any instance variables.
///
/// 5. **Concurrency Safety**: Safe for concurrent use from any thread or actor
///    as all operations are stateless transformations.
///
/// This is likely a temporary workaround that can be removed when Swift's
/// Sendable inference improves for stateless classes.
public final class MockEncryptionService: @unchecked Sendable {
    public init() {}
    
    public func encrypt<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return Data("ENCRYPTED:\(data.base64EncodedString())".utf8)
    }
    
    public func decrypt<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let string = String(data: data, encoding: .utf8)!
        guard string.hasPrefix("ENCRYPTED:") else {
            throw TestError.validationFailed
        }
        let base64 = String(string.dropFirst("ENCRYPTED:".count))
        let realData = Data(base64Encoded: base64)!
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: realData)
    }
}

// MARK: - Test Command Handlers

public final class TestCommandHandler: CommandHandler {
    public typealias CommandType = TestCommand
    
    public init() {}
    
    public func handle(_ command: TestCommand) async throws -> String {
        if command.shouldFail {
            throw PipelineError.executionFailed(message: "Test command failed", context: nil)
        }
        return command.value
    }
}

public final class AsyncTestCommandHandler: CommandHandler {
    public typealias CommandType = AsyncTestCommand
    
    public init() {}
    
    public func handle(_ command: AsyncTestCommand) async throws -> Int {
        try await Task.sleep(nanoseconds: UInt64(command.delay * 1_000_000_000))
        return command.value
    }
}
