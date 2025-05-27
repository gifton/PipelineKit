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
        let successResult: CommandResult<String, any Error> = .success("Success")
        let failureResult: CommandResult<String, any Error> = .failure(TestError.failed)
        
        XCTAssertTrue(successResult.isSuccess)
        XCTAssertFalse(successResult.isFailure)
        XCTAssertFalse(failureResult.isSuccess)
        XCTAssertTrue(failureResult.isFailure)
    }
}

enum TestError: Error, Sendable {
    case failed
}