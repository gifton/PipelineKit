import Synchronization
import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitResilience

final class TimeoutProofTests: XCTestCase {
    private struct TestCommand: Command {
        typealias Result = String
    }

    private final class HandlerCalls: Sendable {
        private let storage = Mutex(0)
        func record() { storage.withLock { $0 += 1 } }
        var count: Int { storage.withLock { $0 } }
    }

    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        let calls: HandlerCalls

        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            calls.record()
            return "unexpected handler execution"
        }
    }

    private struct SuspendedMiddleware: Middleware {
        let priority: ExecutionPriority
        let sleeper: ManualAdmissionClock

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // The clock stays unadvanced: cancellation releases this suspension.
            try await sleeper.sleep(for: .seconds(1))
            return try await next(command, context)
        }
    }

    func testTimeoutWrapsPostProcessingMiddleware() async throws {
        try await assertTimeoutWraps(priority: .postProcessing, suspendedFirst: false)
    }

    func testTimeoutWrapsCustomMiddlewareRegardlessOfInsertionOrder() async throws {
        try await assertTimeoutWraps(priority: .custom, suspendedFirst: true)
    }

    func testTimeoutWrapsPreProcessingMiddleware() async throws {
        try await assertTimeoutWraps(priority: .preProcessing, suspendedFirst: true)
    }

    private func assertTimeoutWraps(
        priority: ExecutionPriority,
        suspendedFirst: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sleeper = ManualAdmissionClock()
        let calls = HandlerCalls()
        let pipeline = StandardPipeline(handler: TestHandler(calls: calls))
        let suspended = SuspendedMiddleware(priority: priority, sleeper: sleeper)
        let timeout = TimeoutMiddleware(defaultTimeout: 0.01)
        if suspendedFirst {
            try await pipeline.addMiddleware(suspended)
            try await pipeline.addMiddleware(timeout)
        } else {
            try await pipeline.addMiddleware(timeout)
            try await pipeline.addMiddleware(suspended)
        }

        let order = await pipeline.middlewareTypes
        XCTAssertEqual(order, ["TimeoutMiddleware", "SuspendedMiddleware"], file: file, line: line)
        do {
            _ = try await pipeline.execute(TestCommand())
            XCTFail("Expected timeout while downstream middleware is suspended", file: file, line: line)
        } catch let error as PipelineError {
            if case .timeout(let duration, _) = error {
                XCTAssertEqual(duration, 0.01, accuracy: 0.000_001, file: file, line: line)
            } else {
                XCTFail("Expected timeout, got \(error)", file: file, line: line)
            }
        }

        XCTAssertEqual(calls.count, 0, file: file, line: line)
        XCTAssertEqual(sleeper.sleepingCount, 0, file: file, line: line)
        XCTAssertEqual(sleeper.completedCount, sleeper.callCount, file: file, line: line)
    }
}
