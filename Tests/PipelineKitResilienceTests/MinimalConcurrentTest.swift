import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore

final class MinimalConcurrentTest: XCTestCase {
    func testMinimalConcurrent() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .suspend
        )
        
        let context = CommandContext()
        
        // When - Just 2 concurrent commands
        async let result1 = middleware.execute(TestCmd(id: 1), context: context) { cmd, _ in
            print("Executing command \(cmd.id)")
            return "done-\(cmd.id)"
        }
        
        async let result2 = middleware.execute(TestCmd(id: 2), context: context) { cmd, _ in
            print("Executing command \(cmd.id)")
            return "done-\(cmd.id)"
        }
        
        // Then
        let r1 = try await result1
        let r2 = try await result2
        
        XCTAssertEqual(r1, "done-1")
        XCTAssertEqual(r2, "done-2")
    }
}

private struct TestCmd: Command {
    typealias Result = String
    let id: Int
}
