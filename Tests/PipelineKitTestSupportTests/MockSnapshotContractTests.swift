import XCTest
import PipelineKit
import PipelineKitTestSupport

final class MockSnapshotContractTests: XCTestCase {
    // Run under Thread Sanitizer to catch unlocked readers in either mock.
    func testConcurrentMockWritersAndSnapshotReaders() async throws {
        let logging = MockLoggingMiddleware()
        let metrics = MockMetricsMiddleware()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask {
                    let context = CommandContext()
                    _ = try await logging.execute(MockCommand(), context: context) { command, context in
                        try await metrics.execute(command, context: context) { command, _ in
                            "Result: \(command.value)"
                        }
                    }
                }
                group.addTask {
                    // Reading elements as well as the count exercises retained snapshots.
                    let commands = logging.loggedCommands
                    let durations = metrics.recordedMetrics
                    XCTAssertTrue(commands.allSatisfy { $0 == "MockCommand" })
                    XCTAssertTrue(durations.allSatisfy { $0.command == "MockCommand" && $0.duration >= 0 })
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(logging.loggedCommands.count, 500)
        XCTAssertEqual(metrics.recordedMetrics.count, 500)
    }
}
