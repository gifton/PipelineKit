import Foundation
import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TestSupportDelayNumericBoundaryTests: XCTestCase {
    private static let throwingEntries = [
        "test-support-async-command", "test-support-async-handler", "test-support-middleware-delay",
        "test-support-factory-delay", "test-support-factory-timeout", "test-support-command-processor"
    ]

    func testThrowingDelayEntryMatrixRejectsInvalidIntervals() async throws {
        let invalid: [TimeInterval] = [
            -1, -.infinity, .infinity, .nan, .greatestFiniteMagnitude,
            Double(UInt64.max) / 1_000_000_000
        ]
        for entry in Self.throwingEntries {
            for interval in invalid {
                do {
                    _ = try await Self.run(entry: entry, delay: interval)
                    XCTFail("\(entry) accepted invalid delay \(interval)")
                } catch TestPipelineError.invalidDelay { }
            }
        }
    }

    func testValidSmallDelaysPreserveEveryEntryResult() async throws {
        for interval: TimeInterval in [0, .leastNonzeroMagnitude, 0.000_001] {
            for entry in Self.throwingEntries {
                let result = try await Self.run(entry: entry, delay: interval)
                XCTAssertEqual(result, 42, entry)
            }
            let subscriber = MockEventSubscriber(processingDelay: interval)
            await subscriber.process(PipelineEvent(name: "accepted", correlationID: "numeric"))
            let events = await subscriber.processedEvents
            XCTAssertEqual(events.map(\.name), ["accepted"])
        }
        let subscriber = MockEventSubscriber()
        await subscriber.process(PipelineEvent(name: "no delay", correlationID: "numeric"))
        let events = await subscriber.processedEvents
        XCTAssertEqual(events.map(\.name), ["no delay"])
    }

    func testProcessorRejectsInvalidDelayBeforeRecordingCommand() async {
        for interval: TimeInterval in [-1, .nan] {
            let processor = MockCommandProcessor(processingDelay: interval)
            do {
                _ = try await processor.process(AsyncTestCommand(delay: 0))
                XCTFail("Invalid processor delay must not be skipped")
            } catch TestPipelineError.invalidDelay {
            } catch {
                XCTFail("Unexpected processor error: \(error)")
            }
            let commands = await processor.getProcessedCommands()
            XCTAssertTrue(commands.isEmpty)
        }
    }

    /// The driver selects one entry/input per isolated process, including invalid
    /// subscriber initializers whose documented policy is a precondition failure.
    func testNumericConfigurationProbe() async {
        let environment = ProcessInfo.processInfo.environment
        guard let entry = environment["PIPELINEKIT_NUMERIC_ENTRY"],
              let raw = environment["PIPELINEKIT_NUMERIC_VALUE"], let value = Double(raw) else { return }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REACHED\n".utf8))
        if entry == "test-support-event-subscriber" {
            _ = MockEventSubscriber(processingDelay: value)
            FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
            return
        }
        let task = Task { [entry, value] in
            // Validate before the cancelled sleep so accepted large values do not
            // turn the boundary probe into a long-running timer.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await TestSupportDelayNumericBoundaryTests.run(entry: entry, delay: value)
            } catch TestPipelineError.invalidDelay {
                FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REJECTED\n".utf8))
                return
            } catch is CancellationError {
            } catch PipelineError.cancelled {
            } catch {
                XCTFail("Unexpected numeric probe error: \(error)")
                return
            }
            FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
        }
        await task.value
    }

    private static func run(entry: String, delay: TimeInterval) async throws -> Int {
        let command = AsyncTestCommand(delay: delay)
        switch entry {
        case "test-support-async-command": return try await command.execute()
        case "test-support-async-handler": return try await AsyncTestCommandHandler().handle(command, context: CommandContext())
        case "test-support-middleware-delay":
            return try await DelayMiddleware(delay: delay).execute(command, context: CommandContext()) { command, _ in command.value }
        case "test-support-factory-delay":
            return try await MockMiddlewareFactory.delay(delay).execute(command, context: CommandContext()) { command, _ in command.value }
        case "test-support-factory-timeout":
            return try await MockMiddlewareFactory.simulatingTimeout(duration: delay).execute(command, context: CommandContext()) { command, _ in command.value }
        case "test-support-command-processor":
            return try await MockCommandProcessor(processingDelay: delay).process(command).value
        default:
            XCTFail("Unknown numeric probe entry: \(entry)")
            return -1
        }
    }
}
