import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitResilience

private struct SlowCommand: Command { typealias Result = String }

private struct SlowHandler: CommandHandler {
    func handle(_ command: SlowCommand, context: CommandContext) async throws -> String {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return "slow"
    }
}

final class ConcurrentPipelineErrorContractTests: XCTestCase {
    // Pins the documented contract: a saturated execute(_:context:timeout:)
    // throws .backPressure(.timeout) — before AND after the dead-branch
    // cleanup this must hold unchanged.
    func testSaturatedExecuteWithTimeoutThrowsBackPressureTimeout() async throws {
        // One execution slot, room for one waiter (maxOutstanding counts
        // executing + queued): the second execute waits, then times out.
        let options = PipelineOptions(maxConcurrency: 1, maxOutstanding: 2)
        let pipeline = ConcurrentPipeline(options: options)
        await pipeline.register(SlowCommand.self, pipeline: StandardPipeline(handler: SlowHandler()))

        let running = Task {
            try await pipeline.execute(
                SlowCommand(),
                context: CommandContext(metadata: DefaultCommandMetadata()),
                timeout: 5.0
            )
        }
        // Let the first execution take the slot.
        try await Task.sleep(nanoseconds: 200_000_000)

        do {
            _ = try await pipeline.execute(
                SlowCommand(),
                context: CommandContext(metadata: DefaultCommandMetadata()),
                timeout: 0.1
            )
            XCTFail("Saturated execute must time out")
        } catch let error as PipelineError {
            guard case .backPressure(let reason) = error, case .timeout = reason else {
                XCTFail("Expected .backPressure(.timeout), got \(error)")
                return
            }
        }

        running.cancel()
        _ = try? await running.value
    }
}
