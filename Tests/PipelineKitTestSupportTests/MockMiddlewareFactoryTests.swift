//
//  MockMiddlewareFactoryTests.swift
//  PipelineKit
//
//  Tests for MockMiddlewareFactory and its middleware types.
//

import XCTest
@testable import PipelineKit
@testable import PipelineKitCore
import PipelineKitTestSupport

// MARK: - Test Commands and Handlers

struct FactoryTestCommand: Command {
    typealias Result = String
    let value: String

    func execute() async throws -> String { value }
}

final class FactoryTestHandler: CommandHandler {
    typealias CommandType = FactoryTestCommand

    func handle(_ command: FactoryTestCommand) async throws -> String {
        command.value
    }
}

// MARK: - MockMiddlewareFactory Tests

final class MockMiddlewareFactoryTests: XCTestCase {

    // MARK: - Factory Method Tests

    func testLoggerCreation() async throws {
        let logger = MockMiddlewareFactory.logger()

        XCTAssertNotNil(logger)
        XCTAssertEqual(logger.executionCount, 0)
    }

    func testDelayCreation() {
        let delay = MockMiddlewareFactory.delay(0.5)

        XCTAssertNotNil(delay)
        XCTAssertEqual(delay.delay, 0.5)
    }

    func testFailingCreation() async throws {
        let failing = MockMiddlewareFactory.failing()

        XCTAssertNotNil(failing)

        // Verify it throws when used
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        do {
            _ = try await failing.execute(command, context: context) { cmd, ctx in
                return cmd.value
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    func testFailingWithCustomError() async throws {
        struct CustomError: Error {}
        let failing = MockMiddlewareFactory.failing(with: CustomError())

        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        do {
            _ = try await failing.execute(command, context: context) { cmd, ctx in
                return cmd.value
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is CustomError)
        }
    }

    func testCounterCreation() {
        let counter = MockMiddlewareFactory.counter()

        XCTAssertNotNil(counter)
        XCTAssertEqual(counter.count, 0)
    }

    func testModifyingCreation() async throws {
        let modifying = MockMiddlewareFactory.modifying { context in
            context.setMetadata("modified", value: true)
        }

        XCTAssertNotNil(modifying)

        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        _ = try await modifying.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        let modified = context.getMetadata("modified") as? Bool ?? false
        XCTAssertTrue(modified)
    }

    func testSimulatingTimeoutCreation() {
        let timeout = MockMiddlewareFactory.simulatingTimeout(duration: 30)

        XCTAssertNotNil(timeout)
        XCTAssertEqual(timeout.delay, 30)
    }

    // MARK: - CapturingMiddleware Tests

    func testCapturingCapturesCommand() async throws {
        let capturing = CapturingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "captured")

        _ = try await capturing.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(capturing.executedCommands.count, 1)
        XCTAssertEqual(capturing.executedCommands.first?.commandType, "FactoryTestCommand")
    }

    func testCapturingCapturesContext() async throws {
        let capturing = CapturingMiddleware()
        let context = CommandContext()
        context.setMetadata("testKey", value: "testValue")
        let command = FactoryTestCommand(value: "test")

        _ = try await capturing.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(capturing.contexts.count, 1)
    }

    func testCapturingCountsExecutions() async throws {
        let capturing = CapturingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        for _ in 0..<5 {
            _ = try await capturing.execute(command, context: context) { cmd, ctx in
                return cmd.value
            }
        }

        XCTAssertEqual(capturing.executionCount, 5)
    }

    func testCapturingReset() async throws {
        let capturing = CapturingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        _ = try await capturing.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(capturing.executionCount, 1)

        capturing.reset()

        XCTAssertEqual(capturing.executionCount, 0)
        XCTAssertTrue(capturing.executedCommands.isEmpty)
        XCTAssertTrue(capturing.contexts.isEmpty)
    }

    func testCapturingThreadSafety() async throws {
        let capturing = CapturingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = try? await capturing.execute(command, context: context) { cmd, ctx in
                        return cmd.value
                    }
                }
            }
        }

        XCTAssertEqual(capturing.executionCount, 100)
    }

    // MARK: - CountingMiddleware Tests

    func testCountingIncrementsOnExecute() async throws {
        let counter = CountingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        XCTAssertEqual(counter.count, 0)

        _ = try await counter.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(counter.count, 1)

        _ = try await counter.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(counter.count, 2)
    }

    func testCountingReset() async throws {
        let counter = CountingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        _ = try await counter.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(counter.count, 1)

        counter.reset()

        XCTAssertEqual(counter.count, 0)
    }

    func testCountingThreadSafety() async throws {
        let counter = CountingMiddleware()
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = try? await counter.execute(command, context: context) { cmd, ctx in
                        return cmd.value
                    }
                }
            }
        }

        XCTAssertEqual(counter.count, 100)
    }

    // MARK: - DelayMiddleware Tests

    func testDelayAddsConfiguredDelay() async throws {
        let delay = DelayMiddleware(delay: 0.1)
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        let start = Date()
        _ = try await delay.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }
        let duration = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(duration, 0.1)
    }

    // MARK: - ConditionalFailingMiddleware Tests

    func testConditionalFailsWhenTrue() async throws {
        let failing = ConditionalFailingMiddleware { command, context in
            return true
        }
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        do {
            _ = try await failing.execute(command, context: context) { cmd, ctx in
                return cmd.value
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    func testConditionalPassesWhenFalse() async throws {
        let failing = ConditionalFailingMiddleware { command, context in
            return false
        }
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        let result = try await failing.execute(command, context: context) { cmd, ctx in
            return cmd.value
        }

        XCTAssertEqual(result, "test")
    }

    func testConditionalFailsBasedOnCommand() async throws {
        let failing = MockMiddlewareFactory.failingWhen { command, context in
            if let cmd = command as? FactoryTestCommand {
                return cmd.value == "fail"
            }
            return false
        }
        let context = CommandContext()

        // Should pass
        let passCommand = FactoryTestCommand(value: "pass")
        let result = try await failing.execute(passCommand, context: context) { cmd, ctx in
            return cmd.value
        }
        XCTAssertEqual(result, "pass")

        // Should fail
        let failCommand = FactoryTestCommand(value: "fail")
        do {
            _ = try await failing.execute(failCommand, context: context) { cmd, ctx in
                return cmd.value
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    // MARK: - ContextModifyingMiddleware Tests

    func testContextModifyingAddsMetadata() async throws {
        let modifying = ContextModifyingMiddleware { context in
            context.setMetadata("added", value: "by middleware")
        }
        let context = CommandContext()
        let command = FactoryTestCommand(value: "test")

        _ = try await modifying.execute(command, context: context) { cmd, ctx in
            let value = ctx.getMetadata("added") as? String
            XCTAssertEqual(value, "by middleware")
            return cmd.value
        }
    }

    func testContextModifyingPriority() {
        let modifying = ContextModifyingMiddleware { _ in }
        XCTAssertEqual(modifying.priority, .preProcessing)
    }
}
