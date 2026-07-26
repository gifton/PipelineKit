import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitResilience

private struct ProbeCommand: Command {
    typealias Result = String
}

private struct ProbeHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> String {
        ExecutionContext.current?.progress?.report(message: "handled")
        return "ok"
    }
}

// Races draining `stream` against a timeout; returns true iff the stream
// terminated (was finished) within `seconds`. Mirrors the helper in
// PipelineKitTests/ExecutionContextBindingTests.swift — test targets cannot
// share private helpers, so the duplication is deliberate.
private func streamTerminates(
    _ stream: AsyncStream<ProgressUpdate>,
    within seconds: UInt64 = 2
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream { }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

final class ConcurrentPipelineProgressTests: XCTestCase {
    func testHandlerNotFoundFinishesAttachedStream() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = ConcurrentPipeline()
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(ProbeCommand(), context: context)
            XCTFail("Unregistered command type must throw")
        } catch is PipelineError {
            // Expected: handlerNotFound.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let terminated = await streamTerminates(stream)
        XCTAssertTrue(terminated, "Stream must finish when no pipeline is registered")
    }

    func testHandlerNotFoundFinishesAttachedStreamOnTimeoutVariant() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = ConcurrentPipeline()
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(ProbeCommand(), context: context, timeout: 1.0)
            XCTFail("Unregistered command type must throw")
        } catch is PipelineError {
            // Expected: handlerNotFound.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let terminated = await streamTerminates(stream)
        XCTAssertTrue(terminated, "Timeout variant must finish the stream when no pipeline is registered")
    }

    func testDelegatedExecutionDeliversAndFinishesStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let concurrent = ConcurrentPipeline()
        await concurrent.register(ProbeCommand.self, pipeline: StandardPipeline(handler: ProbeHandler()))
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        let result = try await concurrent.execute(ProbeCommand(), context: context)
        XCTAssertEqual(result, "ok")

        // The delegated StandardPipeline finishes the stream at its exit;
        // ConcurrentPipeline's later finish() is an idempotent no-op. The
        // for-await terminating pins that interaction.
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["handled"],
                       "Delegated execution must deliver reports and the stream must finish")
    }
}
