import XCTest
import PipelineKit

final class DynamicPipelineRegistrationTests: XCTestCase {
    private struct EchoCommand: Command { typealias Result = String; let text: String }

    private final class EchoHandlerA: CommandHandler {
        typealias CommandType = EchoCommand
        func handle(_ command: EchoCommand) async throws -> String { "A:\(command.text)" }
    }

    private final class EchoHandlerB: CommandHandler {
        typealias CommandType = EchoCommand
        func handle(_ command: EchoCommand) async throws -> String { "B:\(command.text)" }
    }

    func testRegisterOnceInsertsAndExecutes() async throws {
        let pipeline = DynamicPipeline()
        try await pipeline.registerOnce(EchoCommand.self, handler: EchoHandlerA())
        
        let command = EchoCommand(text: "hello")
        let result = try await pipeline.execute(command)
        XCTAssertEqual(result, "A:hello")
    }

    func testRegisterOnceWithExistingKeyThrows() async throws {
        let pipeline = DynamicPipeline()
        try await pipeline.registerOnce(EchoCommand.self, handler: EchoHandlerA())
        
        await XCTAssertThrowsError(
            try await pipeline.registerOnce(EchoCommand.self, handler: EchoHandlerB())
        ) { error in
            if case PipelineError.configurationError(let message) = error {
                XCTAssertTrue(message.contains("already registered"))
            } else {
                XCTFail("Expected configurationError, got \(error)")
            }
        }
    }

    func testRegisterOverwritesHandler() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())
        await pipeline.register(EchoCommand.self, handler: EchoHandlerB())
        
        let command = EchoCommand(text: "overwrite")
        let result = try await pipeline.execute(command)
        XCTAssertEqual(result, "B:overwrite")
    }

    func testUnregisterRemovesHandler() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())
        let removed = await pipeline.unregister(EchoCommand.self)
        XCTAssertTrue(removed)
        
        let command = EchoCommand(text: "missing")
        await XCTAssertThrowsError(
            try await pipeline.execute(command)
        ) { error in
            if case PipelineError.configurationError(let message) = error {
                XCTAssertTrue(message.contains("No handler"))
            } else {
                XCTFail("Expected configurationError, got \(error)")
            }
        }
    }

    func testIsRegisteredChecksExistence() async {
        let pipeline = DynamicPipeline()
        XCTAssertFalse(await pipeline.isRegistered(EchoCommand.self))
        
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())
        XCTAssertTrue(await pipeline.isRegistered(EchoCommand.self))
        
        _ = await pipeline.unregister(EchoCommand.self)
        XCTAssertFalse(await pipeline.isRegistered(EchoCommand.self))
    }

    func testCountReturnsRegistrationCount() async {
        let pipeline = DynamicPipeline()
        XCTAssertEqual(await pipeline.registrationCount(), 0)
        
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())
        XCTAssertEqual(await pipeline.registrationCount(), 1)
    }

    func testClearRemovesAll() async {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())
        XCTAssertEqual(await pipeline.registrationCount(), 1)
        
        await pipeline.clear()
        XCTAssertEqual(await pipeline.registrationCount(), 0)
        XCTAssertFalse(await pipeline.isRegistered(EchoCommand.self))
    }

    func testUnregisterOnMissingReturnsFalse() async {
        let pipeline = DynamicPipeline()
        let removed = await pipeline.unregister(EchoCommand.self)
        XCTAssertFalse(removed)
    }
}
