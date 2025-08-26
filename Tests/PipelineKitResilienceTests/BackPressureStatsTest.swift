import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore

final class BackPressureStatsTest: XCTestCase {
    func testTotalProcessedCounter() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 5,
            maxOutstanding: 20
        )
        
        let context = CommandContext()
        
        // When - Execute 3 commands sequentially
        for i in 0..<3 {
            let command = SimpleTestCommand(value: "test-\(i)")
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                return cmd.value
            }
        }
        
        // Then - Verify stats
        let stats = await middleware.getStats()
        XCTAssertEqual(stats.totalProcessed, 3, "Should have processed 3 commands")
        XCTAssertEqual(stats.maxConcurrency, 5)
        XCTAssertEqual(stats.maxOutstanding, 20)
    }
}

private struct SimpleTestCommand: Command {
    typealias Result = String
    let value: String
}
