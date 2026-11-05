import XCTest
import PipelineKit
import PipelineKitTestSupport

private struct QualificationCommand: Command {
    typealias Result = Int
    let value: Int
}

private struct QualificationHandler: CommandHandler {
    func handle(_ command: QualificationCommand, context: CommandContext) async throws -> Int {
        command.value
    }
}

private struct QualificationMiddleware: Middleware {
    let priority: ExecutionPriority = .processing
    func execute<T: Command>(
        _ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        try await next(command, context)
    }
}

final class PublicTestPipelineTests: XCTestCase {
    func testTypedInterceptionAndRecordingOnlyContract() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: QualificationHandler(), middleware: [QualificationMiddleware()]
        )
        try await pipeline.mockMiddleware(QualificationMiddleware.self, for: QualificationCommand.self) {
            $0.value + 10
        }
        let command = QualificationCommand(value: 7)
        let mocked = try await pipeline.execute(command)
        try check(mocked == 17, "typed middleware mock did not produce its declared result")
        let recorder = await pipeline.getRecorder()
        try check(await recorder.getSuccessCount() == 1, "mock result was not recorded")

        await pipeline.reset()
        let actual = try await pipeline.execute(command)
        try check(actual == 7, "reset did not restore the real handler")
        try await pipeline.delayMiddleware(QualificationMiddleware.self, delay: 0)
        try await pipeline.failMiddleware(QualificationMiddleware.self, after: 0)
        var injectedFailure = false
        do {
            _ = try await pipeline.execute(command)
        } catch is TestPipelineError {
            injectedFailure = true
        }
        try check(injectedFailure, "configured middleware failure was ignored")

        let recordingOnly = TestPipeline(basePipeline: StandardPipeline(handler: QualificationHandler()))
        var rejected = false
        do {
            try await recordingOnly.delayMiddleware(QualificationMiddleware.self, delay: 0)
        } catch is TestPipelineError {
            rejected = true
        }
        try check(rejected, "recording-only wrapper accepted an unsupported interception setting")
        try check(try await recordingOnly.execute(command) == 7, "recording-only execution changed its result")
    }
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw PublicTestFailure(message: message) }
}

private struct PublicTestFailure: Error { let message: String }
