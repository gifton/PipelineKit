import XCTest
import PipelineKit

final class DynamicPipelineRegistrationTests: XCTestCase {
    struct EchoCommand: Command { typealias Result = String; let text: String }

    final class EchoHandlerA: CommandHandler {
        typealias CommandType = EchoCommand
        func handle(_ command: EchoCommand) async throws -> String { "A:\(command.text)" }
    }

    final class EchoHandlerB: CommandHandler {
        typealias CommandType = EchoCommand
        func handle(_ command: EchoCommand) async throws -> String { "B:\(command.text)" }
    }

    func testRegisterOnceInsertsAndExecutes() async throws {
        let pipeline = DynamicPipeline()
        try await pipeline.registerOnce(EchoCommand.self, handler: EchoHandlerA())

        let result = try await pipeline.send(EchoCommand(text: "hello"))
        XCTAssertEqual(result, "A:hello")
    }

    func testRegisterOnceThrowsOnDuplicate() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())

        do {
            try await pipeline.registerOnce(EchoCommand.self, handler: EchoHandlerB())
            XCTFail("Expected duplicate registration to throw")
        } catch let error as PipelineError {
            switch error {
            case .pipelineNotConfigured(let reason):
                XCTAssertTrue(reason.contains("already registered"), "Unexpected reason: \(reason)")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testReplaceReturnsFlagsAndOverridesHandler() async throws {
        let pipeline = DynamicPipeline()
        // First replace should return false (no previous)
        var replaced = await pipeline.replace(EchoCommand.self, with: EchoHandlerA())
        XCTAssertFalse(replaced)

        var result = try await pipeline.send(EchoCommand(text: "x"))
        XCTAssertEqual(result, "A:x")

        // Second replace should return true and override
        replaced = await pipeline.replace(EchoCommand.self, with: EchoHandlerB())
        XCTAssertTrue(replaced)

        result = try await pipeline.send(EchoCommand(text: "y"))
        XCTAssertEqual(result, "B:y")
    }

    func testUnregisterRemovesHandlerAndSendFails() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())

        let removed = await pipeline.unregister(EchoCommand.self)
        XCTAssertTrue(removed)

        do {
            _ = try await pipeline.send(EchoCommand(text: "fail"))
            XCTFail("Expected handlerNotFound error")
        } catch let error as PipelineError {
            switch error {
            case .handlerNotFound(let typeName):
                XCTAssertTrue(typeName.contains("EchoCommand"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRegisterReplaceByDefaultOverridesHandler() async throws {
        let pipeline = DynamicPipeline()
        await pipeline.register(EchoCommand.self, handler: EchoHandlerA())
        // Replace-by-default semantics
        await pipeline.register(EchoCommand.self, handler: EchoHandlerB())

        let result = try await pipeline.send(EchoCommand(text: "z"))
        XCTAssertEqual(result, "B:z")
    }

    func testUnregisterOnMissingReturnsFalse() async {
        let pipeline = DynamicPipeline()
        let removed = await pipeline.unregister(EchoCommand.self)
        XCTAssertFalse(removed)
    }
}

