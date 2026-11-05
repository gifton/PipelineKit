import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TestPipelineProgressContractTests: XCTestCase {
    func testPreCancelledAdmissionFinishesAttachedProgressWithoutStartingWork() async throws {
        for route in ProgressPipelineRoute.allCases {
            let calls = TestActor<[String]>([])
            let pipeline = try await makePipeline(route, calls: calls)
            let (stream, reporter) = ProgressReporter.makeStream()
            let context = CommandContext()
            context[ContextKeys.progressReporter] = reporter
            let execution = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await pipeline.execute(ProgressContractCommand(), context: context)
            }
            do {
                _ = try await execution.value
                XCTFail("Expected cancelled admission for \(route)")
            } catch PipelineError.cancelled { }

            let observation = await observeTermination(stream)
            XCTAssertTrue(observation.finished, "Attached stream must finish for \(route)")
            let started = await calls.get()
            XCTAssertTrue(started.isEmpty, "Cancelled admission must not start handler or mock: \(route)")
            let recorder = await pipeline.getRecorder()
            let records = await recorder.getExecutions()
            XCTAssertEqual(records.count, 1)
            XCTAssertNotNil(records.first?.endTime)
            XCTAssertNotNil(records.first?.error)
        }
    }

    func testChildCancellationLeavesInheritedParentProgressUsable() async throws {
        for route in ProgressPipelineRoute.allCases {
            let pipeline = try await makePipeline(route, calls: TestActor([]))
            let (stream, reporter) = ProgressReporter.makeStream()
            let parent = ExecutionContext(
                trace: TraceMetadata(commandID: UUID(), correlationID: "parent", userID: nil),
                progress: reporter
            )
            await ExecutionContext.$current.withValue(parent) {
                let execution = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await pipeline.execute(ProgressContractCommand(), context: CommandContext())
                }
                do {
                    _ = try await execution.value
                    XCTFail("Expected cancelled child for \(route)")
                } catch PipelineError.cancelled {
                } catch {
                    XCTFail("Unexpected child failure: \(error)")
                }
                ExecutionContext.current?.progress?.report(message: "parent after child")
            }
            reporter.finish()
            let observation = await observeTermination(stream)
            XCTAssertTrue(observation.finished)
            XCTAssertEqual(observation.messages, ["parent after child"], "Inherited ownership must stay with parent: \(route)")
        }
    }

    func testSuccessFinishesAttachedProgressOnEveryRoute() async throws {
        for route in ProgressPipelineRoute.allCases {
            let pipeline = try await makePipeline(route, calls: TestActor([]))
            let (stream, reporter) = ProgressReporter.makeStream()
            let context = CommandContext()
            context[ContextKeys.progressReporter] = reporter
            _ = try await pipeline.execute(ProgressContractCommand(), context: context)
            let observation = await observeTermination(stream)
            XCTAssertTrue(observation.finished, "Success must finish attached progress: \(route)")
            let recorder = await pipeline.getRecorder()
            let count = await recorder.getSuccessCount()
            XCTAssertEqual(count, 1)
        }
    }

    func testFailureFinishesAttachedProgressOnEveryRoute() async throws {
        for route in ProgressPipelineRoute.allCases {
            let pipeline = try await makePipeline(route, calls: TestActor([]), shouldFail: true)
            let (stream, reporter) = ProgressReporter.makeStream()
            let context = CommandContext()
            context[ContextKeys.progressReporter] = reporter
            do {
                if route == .standalone {
                    _ = try await pipeline.execute(UnsupportedProgressCommand(), context: context)
                } else {
                    _ = try await pipeline.execute(ProgressContractCommand(), context: context)
                }
                XCTFail("Expected configured failure for \(route)")
            } catch ProgressContractError.expected {
                XCTAssertNotEqual(route, .standalone)
            } catch TestPipelineError.unsupportedResultType {
                XCTAssertEqual(route, .standalone)
            }
            let observation = await observeTermination(stream)
            XCTAssertTrue(observation.finished, "Failure must finish attached progress: \(route)")
            let recorder = await pipeline.getRecorder()
            let records = await recorder.getExecutions()
            XCTAssertEqual(records.count, 1)
            XCTAssertNotNil(records.first?.endTime)
            XCTAssertNotNil(records.first?.error)
        }
    }

    private func makePipeline(
        _ route: ProgressPipelineRoute,
        calls: TestActor<[String]>,
        shouldFail: Bool = false
    ) async throws -> TestPipeline {
        let handler = ProgressContractHandler(calls: calls, shouldFail: shouldFail)
        switch route {
        case .factory:
            let pipeline = try await PipelineTestUtils.createTestPipeline(
                handler: handler, middleware: [ProgressContractMiddleware()]
            )
            try await pipeline.mockMiddleware(ProgressContractMiddleware.self, for: ProgressContractCommand.self) { _ in
                await calls.append("mock")
                if shouldFail { throw ProgressContractError.expected }
                return "mocked"
            }
            return pipeline
        case .recording:
            return TestPipeline(basePipeline: StandardPipeline(handler: handler))
        case .standalone:
            return TestPipeline()
        }
    }

    private func observeTermination(_ stream: AsyncStream<ProgressUpdate>) async -> ProgressObservation {
        await withTaskGroup(of: ProgressObservation.self) { group in
            group.addTask {
                var messages: [String?] = []
                for await update in stream { messages.append(update.message) }
                return ProgressObservation(finished: !Task.isCancelled, messages: messages)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return ProgressObservation(finished: false, messages: [])
            }
            let observation = await group.next() ?? ProgressObservation(finished: false, messages: [])
            group.cancelAll()
            return observation
        }
    }
}

private enum ProgressPipelineRoute: CaseIterable { case factory, recording, standalone }
private struct ProgressContractCommand: Command { typealias Result = String }
private struct UnsupportedProgressCommand: Command { typealias Result = Int }
private enum ProgressContractError: Error { case expected }
private struct ProgressObservation: Sendable {
    let finished: Bool
    let messages: [String?]
}
private struct ProgressContractHandler: CommandHandler {
    let calls: TestActor<[String]>
    let shouldFail: Bool
    func handle(_ command: ProgressContractCommand, context: CommandContext) async throws -> String {
        await calls.append("handler")
        if shouldFail { throw ProgressContractError.expected }
        return "handled"
    }
}
private struct ProgressContractMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await next(command, context)
    }
}
