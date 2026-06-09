import XCTest
@testable import PipelineKitCore

final class ObserverMiddlewareTests: XCTestCase {
    actor Recorder {
        private(set) var observed: [String] = []
        private(set) var nexts = 0
        func recordObserve(_ s: String) { observed.append(s) }
        func recordNext() { nexts += 1 }
    }

    struct ProbeCommand: Command {
        typealias Result = String
        let value: String
    }

    struct RecordingObserver: ObserverMiddleware {
        let recorder: Recorder
        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            await recorder.recordObserve(String(describing: T.self))
        }
    }

    struct FailingObserver: ObserverMiddleware {
        struct Boom: Error {}
        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            throw Boom()
        }
    }

    func testDefaultExecuteObservesThenForwardsToNext() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let ctx = CommandContext()

        let result = try await observer.execute(ProbeCommand(value: "x"), context: ctx) { cmd, _ in
            await recorder.recordNext()
            return cmd.value
        }

        XCTAssertEqual(result, "x")
        let observed = await recorder.observed
        let nexts = await recorder.nexts
        XCTAssertEqual(observed, ["ProbeCommand"], "observe must run once")
        XCTAssertEqual(nexts, 1, "next must be forwarded exactly once")
    }

    func testThrowingObserverDoesNotCallNext() async {
        let recorder = Recorder()
        let observer = FailingObserver()
        let ctx = CommandContext()

        do {
            _ = try await observer.execute(ProbeCommand(value: "x"), context: ctx) { cmd, _ in
                await recorder.recordNext()
                return cmd.value
            }
            XCTFail("Expected observe() to throw")
        } catch is FailingObserver.Boom {
            let nexts = await recorder.nexts
            XCTAssertEqual(nexts, 0, "next must NOT be called when observe throws")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultPriorityIsObservability() {
        XCTAssertEqual(RecordingObserver(recorder: Recorder()).priority, .observability)
    }
}
