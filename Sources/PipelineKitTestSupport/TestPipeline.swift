//
//  TestPipeline.swift
//  PipelineKit
//
//  Test pipeline with middleware mocking, delay, and failure injection.
//

import Foundation
import XCTest
import PipelineKit
import PipelineKitCore

/// Records executions, with middleware interception when created by
/// `PipelineTestUtils.createTestPipeline(handler:middleware:)`.
public actor TestPipeline: Pipeline {
    private var middlewareSettings: [ObjectIdentifier: TestMiddlewareSettings] = [:]
    private var executionRecorder: TestExecutionRecorder
    private let basePipeline: (any Pipeline)?
    private let interception: TestInterceptionSupport?

    /// Wraps an arbitrary pipeline for recording. Its middleware is opaque, so
    /// configuring middleware interception throws `interceptionUnavailable`.
    public init(basePipeline: (any Pipeline)? = nil) {
        self.basePipeline = basePipeline
        self.executionRecorder = TestExecutionRecorder()
        self.interception = nil
    }

    fileprivate init(basePipeline: any Pipeline, interception: TestInterceptionSupport) {
        self.basePipeline = basePipeline
        self.executionRecorder = TestExecutionRecorder()
        self.interception = interception
    }

    /// Replaces the selected middleware and the remainder of its chain with a
    /// typed result. The command type must match the factory's handler.
    public func mockMiddleware<M: Middleware, C: Command>(
        _ middlewareType: M.Type,
        for commandType: C.Type,
        handler: @escaping @Sendable (C) async throws -> C.Result
    ) throws {
        let key = try middlewareKey(middlewareType)
        guard interception?.commandType == ObjectIdentifier(commandType) else {
            throw TestPipelineError.commandTypeMismatch(String(reflecting: commandType))
        }
        middlewareSettings[key, default: TestMiddlewareSettings()].mock = { command in
            guard let command = command as? C else {
                throw TestPipelineError.commandTypeMismatch(String(reflecting: type(of: command)))
            }
            return try await handler(command)
        }
    }

    /// Adds a cancellable delay before failure injection, mocking, or the original
    /// middleware. The delay must be finite, nonnegative, and fit in nanoseconds.
    public func delayMiddleware<T>(
        _ middlewareType: T.Type,
        delay: TimeInterval
    ) throws where T: Middleware {
        let key = try middlewareKey(middlewareType)
        middlewareSettings[key, default: TestMiddlewareSettings()].delay = try testDelayNanoseconds(delay)
    }

    /// Allows the first `calls` matching middleware entries, then fails every
    /// later entry until reconfiguration or reset. Zero fails the first entry.
    public func failMiddleware<T>(
        _ middlewareType: T.Type,
        after calls: Int
    ) throws where T: Middleware {
        let key = try middlewareKey(middlewareType)
        guard calls >= 0 else { throw TestPipelineError.invalidFailureCount(calls) }
        middlewareSettings[key, default: TestMiddlewareSettings()].failure = TestFailureCountdown(remaining: calls)
    }

    private func middlewareKey<M: Middleware>(_ type: M.Type) throws -> ObjectIdentifier {
        guard let interception else { throw TestPipelineError.interceptionUnavailable }
        let key = ObjectIdentifier(type)
        guard interception.middlewareTypes.contains(key) else {
            throw TestPipelineError.middlewareNotFound(String(reflecting: type))
        }
        return key
    }
    
    /// Execute with recording
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        let startTime = ContinuousClock.now
        let executionId = UUID()
        let recorder = executionRecorder
        let session = TestInterceptionSession(
            owner: interception?.owner,
            settings: middlewareSettings,
            recorder: recorder
        )

        await recorder.recordStart(
            executionId: executionId,
            command: command,
            metadata: context.commandMetadata
        )
        
        do {
            try PipelineCancellation.check(context: context, message: "Test pipeline cancelled before execution")
            let result: T.Result

            if let base = basePipeline {
                result = try await TestInterceptionSession.$current.withValue(session) {
                    try await base.execute(command, context: context)
                }
            } else {
                // Simple mock execution
                if let stringResult = "Mocked result" as? T.Result {
                    result = stringResult
                } else if let voidResult = () as? T.Result {
                    result = voidResult
                } else {
                    throw TestPipelineError.unsupportedResultType
                }
            }
            
            try PipelineCancellation.check(context: context, message: "Test pipeline cancelled after execution")
            await recorder.recordSuccess(
                executionId: executionId,
                result: result,
                duration: elapsedSeconds(since: startTime)
            )
            
            return result
        } catch {
            await recorder.recordFailure(
                executionId: executionId,
                error: error,
                duration: elapsedSeconds(since: startTime)
            )
            throw error
        }
    }
    
    /// Get execution recorder for assertions
    public func getRecorder() -> TestExecutionRecorder {
        executionRecorder
    }
    
    /// Clears controls and creates a recorder for new executions. Already admitted
    /// executions retain their settings and settle in their original recorder
    /// (`testResetSettlesEachInFlightRecordInItsOriginalRecorder`).
    public func reset() {
        middlewareSettings.removeAll()
        executionRecorder = TestExecutionRecorder()
    }
}

private final class TestInterceptionOwner: Sendable {}

private struct TestInterceptionSupport: Sendable {
    let owner: TestInterceptionOwner
    let commandType: ObjectIdentifier
    let middlewareTypes: Set<ObjectIdentifier>
}

private struct TestMiddlewareSettings: Sendable {
    var mock: (@Sendable (any Command) async throws -> any Sendable)?
    var delay: UInt64 = 0
    var failure: TestFailureCountdown?
}

private actor TestFailureCountdown {
    private var remaining: Int
    init(remaining: Int) { self.remaining = remaining }

    func shouldFail() -> Bool {
        guard remaining > 0 else { return true }
        remaining -= 1
        return false
    }
}

private struct TestInterceptionSession: Sendable {
    @TaskLocal static var current: TestInterceptionSession?
    let owner: TestInterceptionOwner?
    let settings: [ObjectIdentifier: TestMiddlewareSettings]
    let recorder: TestExecutionRecorder
}

/// Interception itself may short-circuit. The original middleware receives its own
/// guard only when its body runs (`TestPipelineWarningContractTests`).
private struct TestInterceptingMiddleware: ConditionalMiddleware, UnsafeMiddleware {
    let original: any Middleware
    let owner: TestInterceptionOwner
    var priority: ExecutionPriority { original.priority }

    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
        (original as? any ConditionalMiddleware)?.shouldActivate(for: command, context: context) ?? true
    }

    func execute<T: Command>(
        _ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        guard let session = TestInterceptionSession.current, session.owner === owner else {
            throw TestPipelineError.interceptionUnavailable
        }
        let settings = session.settings[ObjectIdentifier(type(of: original))] ?? TestMiddlewareSettings()
        let name = String(reflecting: type(of: original))
        let started = ContinuousClock.now
        do {
            try PipelineCancellation.check(context: context, message: "Test middleware cancelled before execution")
            if settings.delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: settings.delay)
                } catch {
                    throw PipelineCancellation.normalize(error, context: context, message: "Test middleware delay cancelled")
                }
            }
            if let failure = settings.failure {
                let shouldFail = await failure.shouldFail()
                try PipelineCancellation.check(context: context, message: "Test middleware cancelled after failure reservation")
                if shouldFail { throw TestPipelineError.injectedFailure(name) }
            }
            try PipelineCancellation.check(context: context, message: "Test middleware cancelled before invoking its body")
            let result: T.Result
            if let mock = settings.mock {
                let value = try await mock(command)
                guard let typedValue = value as? T.Result else {
                    throw TestPipelineError.unsupportedResultType
                }
                result = typedValue
            } else {
                // Detached callers do not inherit task locals, and nested pipelines
                // replace them. The continuation owns its admitted session in both
                // cases (the detached/nested continuation tests exercise this).
                let boundNext: MiddlewareNext<T> = { command, context in
                    try await TestInterceptionSession.$current.withValue(session) {
                        try await next(command, context)
                    }
                }
                if original is any UnsafeMiddleware {
                    result = try await original.execute(command, context: context, next: boundNext)
                } else {
                    let nextGuard = NextGuard<T>(
                        boundNext,
                        identifier: name,
                        suppressDeinitWarning: original is any NextGuardWarningSuppressing
                    )
                    do {
                        result = try await original.execute(command, context: context, next: nextGuard.callAsFunction)
                    } catch {
                        nextGuard.markErrorExit()
                        throw error
                    }
                }
            }
            try PipelineCancellation.check(context: context, message: "Test middleware cancelled after execution")
            await session.recorder.recordMiddleware(name: name, duration: elapsedSeconds(since: started), succeeded: true)
            return result
        } catch {
            await session.recorder.recordMiddleware(name: name, duration: elapsedSeconds(since: started), succeeded: false)
            throw error
        }
    }
}

private func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
    let components = start.duration(to: .now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

/// Records pipeline executions for testing (internal test support version)
public actor TestExecutionRecorder {
    private var executions: [TestExecutionRecord] = []
    private var middlewareExecutions: [MiddlewareExecution] = []

    public struct TestExecutionRecord: Sendable {
        public let id: UUID
        public let command: String
        public let metadata: any CommandMetadata
        public let startTime: Date
        public let endTime: Date?
        public let result: String?
        public let error: String?
        public let duration: TimeInterval
    }
    
    public struct MiddlewareExecution: Sendable {
        public let middlewareName: String
        public let executionTime: Date
        public let duration: TimeInterval
        public let succeeded: Bool
    }
    
    func recordStart(executionId: UUID, command: any Command, metadata: any CommandMetadata) {
        let record = TestExecutionRecord(
            id: executionId,
            command: String(describing: type(of: command)),
            metadata: metadata,
            startTime: Date(),
            endTime: nil,
            result: nil,
            error: nil,
            duration: 0
        )
        executions.append(record)
    }
    
    func recordSuccess(executionId: UUID, result: Any, duration: TimeInterval) {
        if let index = executions.firstIndex(where: { $0.id == executionId }) {
            let record = executions[index]
            executions[index] = TestExecutionRecord(
                id: record.id,
                command: record.command,
                metadata: record.metadata,
                startTime: record.startTime,
                endTime: Date(),
                result: String(describing: result),
                error: nil,
                duration: duration
            )
        }
    }
    
    func recordFailure(executionId: UUID, error: any Error, duration: TimeInterval) {
        if let index = executions.firstIndex(where: { $0.id == executionId }) {
            let record = executions[index]
            executions[index] = TestExecutionRecord(
                id: record.id,
                command: record.command,
                metadata: record.metadata,
                startTime: record.startTime,
                endTime: Date(),
                result: nil,
                error: error.localizedDescription,
                duration: duration
            )
        }
    }
    
    func recordMiddleware(name: String, duration: TimeInterval, succeeded: Bool) {
        middlewareExecutions.append(
            MiddlewareExecution(
                middlewareName: name,
                executionTime: Date(),
                duration: duration,
                succeeded: succeeded
            )
        )
    }
    
    public func getExecutions() -> [TestExecutionRecord] {
        executions
    }
    
    public func getMiddlewareExecutions() -> [MiddlewareExecution] {
        middlewareExecutions
    }
    
    public func getTotalExecutions() -> Int {
        executions.count
    }
    
    public func getSuccessCount() -> Int {
        executions.filter { $0.result != nil }.count
    }
    
    public func getFailureCount() -> Int {
        executions.filter { $0.error != nil }.count
    }
    
    public func getAverageDuration() -> TimeInterval? {
        let durations = executions.map { $0.duration }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }
}

/// Test pipeline error
public enum TestPipelineError: LocalizedError, Sendable {
    case unsupportedResultType
    case mockNotConfigured(String)
    case interceptionUnavailable
    case middlewareNotFound(String)
    case commandTypeMismatch(String)
    case invalidDelay(TimeInterval)
    case invalidFailureCount(Int)
    case injectedFailure(String)
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedResultType:
            return "Unsupported result type for mock"
        case .mockNotConfigured(let middleware):
            return "Mock not configured for middleware: \(middleware)"
        case .interceptionUnavailable:
            return "Middleware interception requires PipelineTestUtils.createTestPipeline(handler:middleware:)"
        case .middlewareNotFound(let middleware):
            return "Middleware is not present in the test pipeline: \(middleware)"
        case .commandTypeMismatch(let command):
            return "Mock command type does not match the test pipeline: \(command)"
        case .invalidDelay(let delay):
            return "Delay must be finite, nonnegative, and representable in nanoseconds: \(delay)"
        case .invalidFailureCount(let count):
            return "Allowed middleware call count must be nonnegative: \(count)"
        case .injectedFailure(let middleware):
            return "Injected failure in middleware: \(middleware)"
        }
    }
}

/// Pipeline test utilities
public enum PipelineTestUtils {
    /// Create a test pipeline with common middleware
    public static func createTestPipeline<T: Command, H: CommandHandler>(
        handler: H,
        middleware: [any Middleware] = []
    ) async throws -> TestPipeline where H.CommandType == T {
        let basePipeline = StandardPipeline(handler: handler)
        let owner = TestInterceptionOwner()
        for mw in middleware {
            let wrapped = TestInterceptingMiddleware(original: mw, owner: owner)
            try await basePipeline.addMiddleware(wrapped)
        }

        return TestPipeline(basePipeline: basePipeline, interception: TestInterceptionSupport(
            owner: owner,
            commandType: ObjectIdentifier(T.self),
            middlewareTypes: Set(middleware.map { ObjectIdentifier(type(of: $0)) })
        ))
    }
    
    /// Simulate time-based events
    public static func timeTravel(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: testDelayNanoseconds(seconds))
    }
}

/// XCTest assertions for pipelines
public extension XCTestCase {
    /// Assert pipeline execution succeeds
    func XCTAssertPipelineSucceeds<T: Command>(
        _ pipeline: any Pipeline,
        command: T,
        metadata: any CommandMetadata = DefaultCommandMetadata(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let context = CommandContext(metadata: metadata)
            _ = try await pipeline.execute(command, context: context)
        } catch {
            XCTFail("Pipeline execution failed: \(error)", file: file, line: line)
        }
    }
    
    /// Assert pipeline execution fails
    func XCTAssertPipelineFails<T: Command>(
        _ pipeline: any Pipeline,
        command: T,
        metadata: any CommandMetadata = DefaultCommandMetadata(),
        withError expectedError: (any Error)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let context = CommandContext(metadata: metadata)
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Pipeline execution should have failed", file: file, line: line)
        } catch {
            if let expected = expectedError {
                XCTAssertEqual(
                    error.localizedDescription,
                    expected.localizedDescription,
                    file: file,
                    line: line
                )
            }
        }
    }
    
    /// Assert pipeline performance
    func XCTAssertPipelinePerformance<T: Command>(
        _ pipeline: any Pipeline,
        command: T,
        metadata: any CommandMetadata = DefaultCommandMetadata(),
        within duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let startTime = Date()
        
        do {
            let context = CommandContext(metadata: metadata)
            _ = try await pipeline.execute(command, context: context)
        } catch {
            XCTFail("Pipeline execution failed: \(error)", file: file, line: line)
            return
        }
        
        let executionTime = Date().timeIntervalSince(startTime)
        XCTAssertLessThanOrEqual(
            executionTime,
            duration,
            "Pipeline took \(executionTime)s, expected less than \(duration)s",
            file: file,
            line: line
        )
    }
}

/// Chaos testing utilities
public actor ChaosMonkey {
    private var chaosEnabled = false
    private var failureRate: Double = 0.1
    private var delayRange: ClosedRange<TimeInterval> = 0...0.1
    
    public init() {}
    
    public func enable(failureRate: Double = 0.1, delayRange: ClosedRange<TimeInterval> = 0...0.1) {
        self.chaosEnabled = true
        self.failureRate = failureRate
        self.delayRange = delayRange
    }
    
    public func disable() {
        self.chaosEnabled = false
    }
    
    public func maybeInjectChaos() async throws {
        guard chaosEnabled else { return }
        guard failureRate.isFinite, (0...1).contains(failureRate) else {
            throw ChaosError.invalidFailureRate
        }
        _ = try testDelayNanoseconds(delayRange.lowerBound)
        _ = try testDelayNanoseconds(delayRange.upperBound)
        try Task.checkCancellation()

        // Random delay
        let delay = TimeInterval.random(in: delayRange)
        if delay > 0 {
            try await Task.sleep(nanoseconds: testDelayNanoseconds(delay))
        }
        
        // Random failure
        if Double.random(in: 0...1) < failureRate {
            throw ChaosError.randomFailure
        }
    }
}

public enum ChaosError: LocalizedError {
    case randomFailure
    case invalidFailureRate

    public var errorDescription: String? {
        switch self {
        case .randomFailure: "Chaos monkey induced failure"
        case .invalidFailureRate: "Chaos failure rate must be finite and between zero and one"
        }
    }
}
