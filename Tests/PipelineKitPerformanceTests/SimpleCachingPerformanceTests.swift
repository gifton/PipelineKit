import XCTest
import PipelineKitCache
import PipelineKit
import PipelineKitCore

final class SimpleCachingPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if targetEnvironment(simulator)
        throw XCTSkip("Performance measurements are not meaningful on emulated simulator runners")
        #endif
    }

    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }

    private final class TestHandler: CommandHandler {
        typealias CommandType = TestCommand

        let response: String

        init(response: String = "test-result") {
            self.response = response
        }

        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            return response
        }
    }

    private static let fixtureKey = ClosureCacheKeyGenerator { command, context, _ in
        guard let command = command as? TestCommand else {
            preconditionFailure("Unexpected simple cache performance command")
        }
        let fields: [String?] = ["test-result-v1", command.id, context.commandMetadata.userID]
        return String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
    }

    func testCachingPerformance() throws {
        let cache = SimpleCachingMiddleware(ttl: 300, keyGenerator: Self.fixtureKey)
        let iterations = 10000

        measure(metrics: [XCTClockMetric()]) {
            let expectation = expectation(description: "Performance test")
            expectation.expectedFulfillmentCount = iterations

            Task {
                var completedIterations = 0
                do {
                    let pipeline = StandardPipeline(handler: TestHandler())
                    try await pipeline.addMiddleware(cache)
                    let context = CommandContext()

                    for _ in 0..<iterations {
                        _ = try await pipeline.execute(TestCommand(id: "perf"), context: context)
                        expectation.fulfill()
                        completedIterations += 1
                    }
                } catch {
                    XCTFail("Caching performance workload failed: \(error)")
                    for _ in completedIterations..<iterations {
                        expectation.fulfill()
                    }
                }
            }

            wait(for: [expectation], timeout: 10)
        }
    }
}
