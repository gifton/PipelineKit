import XCTest
import PipelineKit
import PipelineKitCore

// Reads the task-local from a plain function several frames below the
// handler — the whole point of the feature.
private func deepHelperTrace() -> TraceMetadata? {
    ExecutionContext.current?.trace
}

private struct ProbeCommand: Command {
    typealias Result = TraceMetadata?
}

private struct ProbeHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        ExecutionContext.current?.progress?.report(fraction: 0.5, message: "probing")
        return deepHelperTrace()
    }
}

private struct ProbeError: Error {}

private struct ThrowingHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        ExecutionContext.current?.progress?.report(message: "before-throw")
        throw ProbeError()
    }
}

// Handler that fails once then succeeds on retry, reporting progress
private actor AttemptTrackingHandler: CommandHandler {
    private var attemptCount = 0

    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        attemptCount += 1
        let count = attemptCount

        if count == 1 {
            ExecutionContext.current?.progress?.report(message: "attempt-1-failed")
            throw ProbeError()
        }
        ExecutionContext.current?.progress?.report(message: "attempt-2-succeeded")
        return deepHelperTrace()
    }
}


// Actor to safely capture trace observed in middleware
private actor TraceCapture: Sendable {
    private var captured: TraceMetadata? = nil

    func capture(_ trace: TraceMetadata?) {
        self.captured = trace
    }

    func getCaptured() -> TraceMetadata? {
        self.captured
    }
}

// Middleware that captures the current ExecutionContext trace
private struct TraceCapturingMiddleware: Middleware {
    let priority = ExecutionPriority.custom
    let capture: TraceCapture

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // Capture the trace inside the middleware to prove binding wraps it
        await capture.capture(ExecutionContext.current?.trace)
        return try await next(command, context)
    }
}

final class ExecutionContextBindingTests: XCTestCase {
    func testStandardPipelineBindsTraceFromContextMetadata() async throws {
        let pipeline = StandardPipeline(handler: ProbeHandler())
        let metadata = DefaultCommandMetadata(userID: "user-1", correlationID: "corr-1")
        let context = CommandContext(metadata: metadata)

        let seen = try await pipeline.execute(ProbeCommand(), context: context)

        XCTAssertEqual(seen?.commandID, metadata.id)
        XCTAssertEqual(seen?.correlationID, "corr-1")
        XCTAssertEqual(seen?.userID, "user-1")
        XCTAssertNil(ExecutionContext.current, "Binding must not leak past execute")
    }

    func testStandardPipelineDeliversProgressAndFinishesStreamOnSuccess() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = StandardPipeline(handler: ProbeHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await pipeline.execute(ProbeCommand(), context: context)

        // The for-await loop completing proves the pipeline finished the stream.
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["probing"])
    }

    func testStandardPipelineFinishesStreamWhenHandlerThrows() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = StandardPipeline(handler: ThrowingHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(ProbeCommand(), context: context)
            XCTFail("ThrowingHandler must throw")
        } catch is ProbeError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["before-throw"], "Stream must terminate even on a throwing handler")
    }

    func testStandardPipelineBindsTraceAroundMiddlewareChain() async throws {
        let capture = TraceCapture()
        let pipeline = StandardPipeline(handler: ProbeHandler())
        try await pipeline.addMiddleware(TraceCapturingMiddleware(capture: capture))

        let metadata = DefaultCommandMetadata(userID: "middleware-user", correlationID: "middleware-corr")
        let context = CommandContext(metadata: metadata)

        let handlerSaw = try await pipeline.execute(ProbeCommand(), context: context)
        let middlewareSaw = await capture.getCaptured()

        // Both middleware and handler should see the same trace
        XCTAssertNotNil(middlewareSaw, "Middleware must see ExecutionContext.current")
        XCTAssertEqual(middlewareSaw?.commandID, metadata.id)
        XCTAssertEqual(middlewareSaw?.correlationID, "middleware-corr")
        XCTAssertEqual(middlewareSaw?.userID, "middleware-user")

        // Handler should see the same trace (proving binding wraps the whole chain)
        XCTAssertNotNil(handlerSaw)
        XCTAssertEqual(handlerSaw?.commandID, middlewareSaw?.commandID)
        XCTAssertEqual(handlerSaw?.correlationID, middlewareSaw?.correlationID)
        XCTAssertEqual(handlerSaw?.userID, middlewareSaw?.userID)
    }

    func testDynamicPipelineBindsSameTraceAsStandardPipeline() async throws {
        let metadata = DefaultCommandMetadata(userID: "user-p", correlationID: "corr-p")

        let standard = StandardPipeline(handler: ProbeHandler())
        let viaStandard = try await standard.execute(
            ProbeCommand(), context: CommandContext(metadata: metadata)
        )

        let dynamic = DynamicPipeline()
        await dynamic.register(ProbeCommand.self, handler: ProbeHandler())
        let viaDynamic = try await dynamic.execute(
            ProbeCommand(), context: CommandContext(metadata: metadata)
        )

        XCTAssertNotNil(viaStandard)
        XCTAssertEqual(viaStandard, viaDynamic, "Both pipelines must bind identical trace for the same metadata")
    }

    func testDynamicPipelineFinishesProgressStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let dynamic = DynamicPipeline()
        await dynamic.register(ProbeCommand.self, handler: ProbeHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await dynamic.execute(ProbeCommand(), context: context)

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["probing"])
    }

    func testDynamicPipelineDeliversProgressFromRetryAttempt() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let dynamic = DynamicPipeline()
        let handler = AttemptTrackingHandler()
        await dynamic.register(ProbeCommand.self, handler: handler)
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        // Use retry policy that retries on failure
        let result = try await dynamic.send(
            ProbeCommand(),
            context: context,
            retryPolicy: RetryPolicy(maxAttempts: 2)
        )

        // Should have succeeded on attempt 2
        XCTAssertNotNil(result)

        // Collect all progress messages from the stream
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }

        // Stream should contain both messages and complete (not drop attempt-2 message)
        XCTAssertEqual(messages, ["attempt-1-failed", "attempt-2-succeeded"],
                       "Progress stream must deliver messages from all retry attempts before finishing")
    }
}
