import XCTest
@testable import PipelineKit
@testable import _ResilienceCore

final class ParallelObserverTests: XCTestCase {
    actor Recorder {
        private(set) var seen: Set<String> = []
        private(set) var nextCount = 0
        func add(_ s: String) { seen.insert(s) }
        func bumpNext() { nextCount += 1 }
    }
    struct ProbeCommand: Command { typealias Result = String; let value: String }
    struct TagObserver: ObserverMiddleware {
        let tag: String
        let recorder: Recorder
        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            await recorder.add(tag)
        }
    }
    struct ThrowingObserver: ObserverMiddleware {
        struct Boom: Error {}
        func observe<T: Command>(_ command: T, context: CommandContext) async throws { throw Boom() }
    }

    func testAllObserversRunThenNextRunsOnce() async throws {
        let recorder = Recorder()
        let wrapper = ParallelMiddlewareWrapper(observers: [
            TagObserver(tag: "a", recorder: recorder),
            TagObserver(tag: "b", recorder: recorder),
            TagObserver(tag: "c", recorder: recorder)
        ])
        let ctx = CommandContext()
        let result = try await wrapper.execute(ProbeCommand(value: "ok"), context: ctx) { cmd, _ in
            await recorder.bumpNext()
            return cmd.value
        }
        XCTAssertEqual(result, "ok")
        let seen = await recorder.seen
        XCTAssertEqual(seen, ["a", "b", "c"], "every observer must run")
        let nextCount = await recorder.nextCount
        XCTAssertEqual(nextCount, 1, "next must run exactly once")
    }

    func testThrowingObserverFailsCommand() async {
        let recorder = Recorder()
        let wrapper = ParallelMiddlewareWrapper(observers: [
            TagObserver(tag: "a", recorder: recorder),
            ThrowingObserver()
        ])
        let ctx = CommandContext()
        do {
            _ = try await wrapper.execute(ProbeCommand(value: "ok"), context: ctx) { cmd, _ in cmd.value }
            XCTFail("Expected a thrown observer to fail the command")
        } catch is ThrowingObserver.Boom {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyObserversJustRunsNext() async throws {
        let wrapper = ParallelMiddlewareWrapper(observers: [])
        let ctx = CommandContext()
        let result = try await wrapper.execute(ProbeCommand(value: "passthrough"), context: ctx) { cmd, _ in
            cmd.value
        }
        XCTAssertEqual(result, "passthrough")
    }
}
