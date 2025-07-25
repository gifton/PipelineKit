import XCTest
@testable import PipelineKit

final class CommandTests: XCTestCase {
    
    struct LocalTestCommand: Command {
        typealias Result = String
        let value: Int
        
        func execute() async throws -> String {
            return "Executed: \(value)"
        }
    }
    
    struct TestHandler: CommandHandler {
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
        let metadata = StandardCommandMetadata(
            userId: "test-user",
            correlationId: "test-correlation"
        )
        
        XCTAssertEqual(metadata.userId, "test-user")
        XCTAssertEqual(metadata.correlationId, "test-correlation")
        XCTAssertNotNil(metadata.id)
        XCTAssertNotNil(metadata.timestamp)
    }
    
    func testCommandContext() async throws {
        let context = CommandContext.test(
            userId: "user-123",
            correlationId: "corr-123",
            additionalData: ["key": "value"]
        )
        
        let metadata = context.commandMetadata
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata.userId, "user-123")
        XCTAssertEqual(metadata.correlationId, "corr-123")
    }
    
    func testCommandContextWithCustomKeys() async throws {
        let context = CommandContext.test()
        
        // Set values using proper context keys
        context.set("customValue", for: TestCustomValueKey.self)
        context.set(42, for: TestNumberKey.self)
        
        let customValue = context.get(TestCustomValueKey.self)
        let numberValue = context.get(TestNumberKey.self)
        
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

