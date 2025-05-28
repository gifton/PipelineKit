import XCTest
@testable import PipelineKit

final class CommandTests: XCTestCase {
    
    struct TestCommand: Command {
        typealias Result = String
        let value: Int
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Processed: \(command.value)"
        }
    }
    
    func testCommandSendableConformance() async throws {
        let command = TestCommand(value: 42)
        let handler = TestHandler()
        
        let result = try await handler.handle(command)
        XCTAssertEqual(result, "Processed: 42")
    }
    
    func testCommandMetadata() {
        let metadata = DefaultCommandMetadata(
            userId: "test-user",
            correlationId: "test-correlation"
        )
        
        XCTAssertEqual(metadata.userId, "test-user")
        XCTAssertEqual(metadata.correlationId, "test-correlation")
        XCTAssertNotNil(metadata.id)
        XCTAssertNotNil(metadata.timestamp)
    }
    
    func testCommandResult() {
        let successResult: Result<String, any Error> = .success("Success")
        let failureResult: Result<String, any Error> = .failure(TestError.failed)
        
        switch successResult {
        case .success:
            XCTAssertTrue(true, "Success result should be success")
        case .failure:
            XCTFail("Success result should not be failure")
        }
        
        switch failureResult {
        case .success:
            XCTFail("Failure result should not be success")
        case .failure:
            XCTAssertTrue(true, "Failure result should be failure")
        }
    }
}

enum TestError: Error, Sendable {
    case failed
}