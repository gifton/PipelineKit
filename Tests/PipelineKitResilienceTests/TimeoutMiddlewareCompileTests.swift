import XCTest
import PipelineKitCore
import PipelineKitResilience

final class TimeoutMiddlewareCompileTests: XCTestCase {
    func testExecuteAcceptsStoredSendableNextClosure() async throws {
        let capturedValue = "stored"
        let next: MiddlewareNext<DummyCommand> = { _, _ in capturedValue }
        assertNonEscaping(next)

        let result = try await TimeoutMiddleware(defaultTimeout: 60).execute(
            DummyCommand(), context: CommandContext(), next: next
        )
        XCTAssertEqual(result, "stored")
    }

    func testSupportedFixedGraceConfiguration() async throws {
        let configuration = TimeoutMiddleware.Configuration(
            defaultTimeout: 60,
            commandTimeouts: ["DummyCommand": 30],
            gracePeriod: 2,
            timeoutResolver: { _ in 60 },
            timeoutHandler: { _, _ in },
            emitEvents: false,
            metricsCollector: nil
        )
        XCTAssertEqual(configuration.defaultTimeout, 60, accuracy: 0.000001)
        XCTAssertEqual(configuration.gracePeriod, 2, accuracy: 0.000001)
        XCTAssertFalse(configuration.emitEvents)
        let result = try await TimeoutMiddleware(configuration: configuration).execute(
            DummyCommand(), context: CommandContext()
        ) { _, _ in "fixed grace" }
        XCTAssertEqual(result, "fixed grace")
    }

    func testCommandTimeoutAndResolverConvenienceInitializers() async throws {
        let middleware = [
            TimeoutMiddleware(commandTimeouts: ["DummyCommand": 60], defaultTimeout: 30),
            TimeoutMiddleware(defaultTimeout: 30, timeoutResolver: { _ in 60 })
        ]
        for instance in middleware {
            let result = try await instance.execute(DummyCommand(), context: CommandContext()) { _, _ in "supported" }
            XCTAssertEqual(result, "supported")
        }
    }

    func testGracePeriodBackoffRemainsAnIndependentCalculator() {
        let backoff = GracePeriodBackoff(initialDuration: 0.5, maxDuration: 2, multiplier: 2, jitter: 0)
        XCTAssertEqual(backoff.nextDuration(attemptNumber: 1), 0.5, accuracy: 0.000001)
        XCTAssertEqual(backoff.nextDuration(attemptNumber: 2), 1, accuracy: 0.000001)
        XCTAssertEqual(backoff.nextDuration(attemptNumber: 3), 2, accuracy: 0.000001)
    }
}

private struct DummyCommand: Command {
    typealias Result = String
}
