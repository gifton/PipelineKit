import XCTest
import PipelineKitCore
import PipelineKit
import PipelineKitTestSupport

/// Performance tests for core pipeline operations
final class PipelinePerformanceTests: XCTestCase {
    // MARK: - Test Types

    private struct PerformanceCommand: Command {
        typealias Result = Int
        let value: Int

        init(value: Int = 42) {
            self.value = value
        }
    }

    private final class PerformanceHandler: CommandHandler {
        typealias CommandType = PerformanceCommand

        func handle(_ command: PerformanceCommand) async throws -> Int {
            return command.value * 2
        }
    }

    private struct SimpleMiddleware: Middleware {
        let priority: ExecutionPriority

        init(priority: ExecutionPriority = .custom) {
            self.priority = priority
        }

        func execute<C: Command>(
            _ command: C,
            context: CommandContext,
            next: @escaping @Sendable (C, CommandContext) async throws -> C.Result
        ) async throws -> C.Result {
            return try await next(command, context)
        }
    }

    // MARK: - Performance Tests

    func testSimplePipelineExecutionPerformance() throws {
        let pipeline = StandardPipeline(handler: PerformanceHandler())
        let context = CommandContext()
        let command = PerformanceCommand()

        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric(),
            XCTStorageMetric()
        ]) {
            let expectation = expectation(description: "Pipeline execution")
            expectation.expectedFulfillmentCount = 1000

            Task {
                for _ in 0..<1000 {
                    _ = try await pipeline.execute(command, context: context)
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 10)
        }
    }

    func testPipelineWithSingleMiddlewarePerformance() throws {
        let pipeline = StandardPipeline(handler: PerformanceHandler())
        let middleware = SimpleMiddleware()

        let setupExpectation = expectation(description: "Setup")
        Task {
            try await pipeline.addMiddleware(middleware)
            setupExpectation.fulfill()
        }
        wait(for: [setupExpectation], timeout: 1)

        let context = CommandContext()
        let command = PerformanceCommand()

        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Pipeline with middleware")
            expectation.expectedFulfillmentCount = 1000

            Task {
                for _ in 0..<1000 {
                    _ = try await pipeline.execute(command, context: context)
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 10)
        }
    }

    func testPipelineWithMultipleMiddlewarePerformance() throws {
        let pipeline = StandardPipeline(handler: PerformanceHandler())

        // Add 5 middleware components
        let setupExpectation = expectation(description: "Setup middleware")
        Task {
            for i in 0..<5 {
                let priority: ExecutionPriority = switch i {
                case 0: .authentication
                case 1: .validation
                case 2: .custom
                case 3: .postProcessing
                default: .custom
                }
                try await pipeline.addMiddleware(SimpleMiddleware(priority: priority))
            }
            setupExpectation.fulfill()
        }
        wait(for: [setupExpectation], timeout: 2)

        let context = CommandContext()
        let command = PerformanceCommand()

        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Pipeline with multiple middleware")
            expectation.expectedFulfillmentCount = 1000

            Task {
                for _ in 0..<1000 {
                    _ = try await pipeline.execute(command, context: context)
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 10)
        }
    }

    func testConcurrentPipelineExecutionPerformance() throws {
        let pipeline = StandardPipeline(handler: PerformanceHandler())
        let context = CommandContext()
        let command = PerformanceCommand()

        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Concurrent execution")
            expectation.expectedFulfillmentCount = 1000

            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<1000 {
                        group.addTask {
                            _ = try? await pipeline.execute(command, context: context)
                            expectation.fulfill()
                        }
                    }
                }
            }

            wait(for: [expectation], timeout: 10)
        }
    }

    // MARK: - Baseline Options

    func testBaselineOptions() throws {
        // Configure baseline options for performance tests
        let options = XCTMeasureOptions()
        options.iterationCount = 10

        // Only use baseline in non-CI environments
        if ProcessInfo.processInfo.environment["CI"] == nil {
            // Set baseline for comparison (if available in Xcode)
            // Note: Baseline comparison is primarily an Xcode feature
        }

        let pipeline = StandardPipeline(handler: PerformanceHandler())
        let context = CommandContext()
        let command = PerformanceCommand()

        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = expectation(description: "Baseline test")
            expectation.expectedFulfillmentCount = 100

            Task {
                for _ in 0..<100 {
                    _ = try await pipeline.execute(command, context: context)
                    expectation.fulfill()
                }
            }

            wait(for: [expectation], timeout: 5)
        }
    }
}
