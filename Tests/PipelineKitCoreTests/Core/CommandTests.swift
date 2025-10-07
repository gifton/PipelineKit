import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

final class CommandTests: XCTestCase {
    private struct LocalTestCommand: Command {
        typealias Result = String
        let value: Int
        
        func execute() async throws -> String {
            return "Executed: \(value)"
        }
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = LocalTestCommand
        
        func handle(_ command: LocalTestCommand) async throws -> String {
            return "Processed: \(command.value)"
        }
    }
    
    func testCommandSendableConformance() async throws {
        let command = LocalTestCommand(value: 42)
        let handler = TestHandler()
        
        let result = try await handler.handle(command)
        XCTAssertEqual(result, "Processed: 42")
    }
    
    func testCommandExecution() async throws {
        let command = LocalTestCommand(value: 10)
        let result = try await command.execute()
        XCTAssertEqual(result, "Executed: 10")
    }
    
    func testCommandMetadata() async throws {
        let metadata = TestCommandMetadata(
            userID: "test-user",
            correlationID: "test-correlation"
        )
        
        XCTAssertEqual(metadata.userID, "test-user")
        XCTAssertEqual(metadata.correlationID, "test-correlation")
        XCTAssertNotNil(metadata.id)
        XCTAssertNotNil(metadata.timestamp)
    }
    
    func testCommandContext() async throws {
        let context = CommandContext.test(
            userID: "user-123",
            correlationID: "corr-123",
            additionalData: ["key": "value"]
        )
        
        let metadata = context.commandMetadata
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata.userID, "user-123")
        XCTAssertEqual(metadata.correlationID, "corr-123")
    }
    
    func testCommandContextWithCustomKeys() async throws {
        let context = CommandContext.test()
        
        // Set values using string keys
        context.setMetadata("test_custom_value", value: "customValue")
        context.setMetadata("test_number", value: 42)
        
        let customValue = (context.getMetadata()["test_custom_value"] as? String)
        let numberValue = (context.getMetadata()["test_number"] as? Int)
        
        XCTAssertEqual(customValue, "customValue")
        XCTAssertEqual(numberValue, 42)
    }
    
    func testCommandResult() {
        let successResult: Result<String, any Error> = .success("Success")
        let failureResult: Result<String, any Error> = .failure(TestError.commandFailed)
        
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
