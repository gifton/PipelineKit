import Foundation
import XCTest

/// Test pipeline for unit testing with recording and mocking capabilities
public actor TestPipeline: Pipeline {
    private var middlewareMocks: [String: Any] = [:]
    private var middlewareDelays: [String: TimeInterval] = [:]
    private var middlewareFailures: [String: (count: Int, after: Int)] = [:]
    private var executionRecorder: ExecutionRecorder
    private let basePipeline: (any Pipeline)?
    
    public init(basePipeline: (any Pipeline)? = nil) {
        self.basePipeline = basePipeline
        self.executionRecorder = ExecutionRecorder()
    }
    
    /// Mock a middleware to return a specific value
    public func mockMiddleware<T>(
        _ middlewareType: T.Type,
        handler: @escaping @Sendable (Any) async throws -> Any
    ) where T: Middleware {
        let key = String(describing: middlewareType)
        middlewareMocks[key] = handler
    }
    
    /// Add delay to a middleware for testing timeouts
    public func delayMiddleware<T>(
        _ middlewareType: T.Type,
        delay: TimeInterval
    ) where T: Middleware {
        let key = String(describing: middlewareType)
        middlewareDelays[key] = delay
    }
    
    /// Make a middleware fail after N calls
    public func failMiddleware<T>(
        _ middlewareType: T.Type,
        after calls: Int
    ) where T: Middleware {
        let key = String(describing: middlewareType)
        middlewareFailures[key] = (count: 0, after: calls)
    }
    
    /// Execute with recording
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        let startTime = Date()
        let executionId = UUID()
        
        await executionRecorder.recordStart(
            executionId: executionId,
            command: command,
            metadata: await context.commandMetadata
        )
        
        do {
            let result: T.Result
            
            if let base = basePipeline {
                result = try await base.execute(command, context: context)
            } else {
                // Simple mock execution
                if T.Result.self == String.self {
                    result = "Mocked result" as! T.Result
                } else if T.Result.self == Void.self {
                    result = () as! T.Result
                } else {
                    throw TestPipelineError.unsupportedResultType
                }
            }
            
            await executionRecorder.recordSuccess(
                executionId: executionId,
                result: result,
                duration: Date().timeIntervalSince(startTime)
            )
            
            return result
        } catch {
            await executionRecorder.recordFailure(
                executionId: executionId,
                error: error,
                duration: Date().timeIntervalSince(startTime)
            )
            throw error
        }
    }
    
    /// Get execution recorder for assertions
    public func getRecorder() -> ExecutionRecorder {
        executionRecorder
    }
    
    /// Reset all mocks and recordings
    public func reset() {
        middlewareMocks.removeAll()
        middlewareDelays.removeAll()
        middlewareFailures.removeAll()
        executionRecorder = ExecutionRecorder()
    }
}

/// Records pipeline executions for testing
public actor ExecutionRecorder {
    private var executions: [ExecutionRecord] = []
    private var middlewareExecutions: [MiddlewareExecution] = []
    
    public struct ExecutionRecord: Sendable {
        public let id: UUID
        public let command: String
        public let metadata: CommandMetadata
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
    
    func recordStart(executionId: UUID, command: any Command, metadata: CommandMetadata) {
        let record = ExecutionRecord(
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
            executions[index] = ExecutionRecord(
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
    
    func recordFailure(executionId: UUID, error: Error, duration: TimeInterval) {
        if let index = executions.firstIndex(where: { $0.id == executionId }) {
            let record = executions[index]
            executions[index] = ExecutionRecord(
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
    
    public func getExecutions() -> [ExecutionRecord] {
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
public enum TestPipelineError: LocalizedError {
    case unsupportedResultType
    case mockNotConfigured(String)
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedResultType:
            return "Unsupported result type for mock"
        case .mockNotConfigured(let middleware):
            return "Mock not configured for middleware: \(middleware)"
        }
    }
}

/// Pipeline test utilities
public struct PipelineTestUtils {
    /// Create a test pipeline with common middleware
    public static func createTestPipeline<T: Command, H: CommandHandler>(
        handler: H,
        middleware: [any Middleware] = []
    ) async throws -> TestPipeline where H.CommandType == T {
        let basePipeline = DefaultPipeline(handler: handler)
        
        for mw in middleware {
            try await basePipeline.addMiddleware(mw)
        }
        
        return TestPipeline(basePipeline: basePipeline)
    }
    
    /// Simulate time-based events
    public static func timeTravel(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// XCTest assertions for pipelines
public extension XCTestCase {
    /// Assert pipeline execution succeeds
    func XCTAssertPipelineSucceeds<T: Command>(
        _ pipeline: any Pipeline,
        command: T,
        metadata: CommandMetadata = StandardCommandMetadata(),
        file: StaticString = #file,
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
        metadata: CommandMetadata = StandardCommandMetadata(),
        withError expectedError: Error? = nil,
        file: StaticString = #file,
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
        metadata: CommandMetadata = StandardCommandMetadata(),
        within duration: TimeInterval,
        file: StaticString = #file,
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
        
        // Random delay
        let delay = TimeInterval.random(in: delayRange)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        
        // Random failure
        if Double.random(in: 0...1) < failureRate {
            throw ChaosError.randomFailure
        }
    }
}

public enum ChaosError: LocalizedError {
    case randomFailure
    
    public var errorDescription: String? {
        "Chaos monkey induced failure"
    }
}