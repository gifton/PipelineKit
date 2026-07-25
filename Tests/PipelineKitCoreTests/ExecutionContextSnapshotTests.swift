import XCTest
@testable import PipelineKitCore

final class ExecutionContextSnapshotTests: XCTestCase {
    private func makeTrace() -> TraceMetadata {
        TraceMetadata(commandID: UUID(), correlationID: "corr-s", userID: "user-s")
    }

    func testSnapshotCapturesTraceAndRoundTripsThroughCodable() throws {
        let trace = makeTrace()
        let snapshot = ExecutionContext(trace: trace).snapshot()
        XCTAssertEqual(snapshot.trace, trace)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ExecutionContext.Snapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testWithRestoredBindsTraceAndFreshReporterThenUnwinds() async throws {
        let snapshot = ExecutionContext.Snapshot(trace: makeTrace())
        let (stream, reporter) = ProgressReporter.makeStream()

        let seen = await ExecutionContext.withRestored(snapshot, progress: reporter) {
            ExecutionContext.current?.progress?.report(message: "from-worker")
            return ExecutionContext.current?.trace
        }
        XCTAssertEqual(seen, snapshot.trace)
        XCTAssertNil(ExecutionContext.current, "Binding must unwind after withRestored")

        reporter.finish()
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["from-worker"], "Restored context must carry the fresh reporter")
    }

    func testNestedWithRestoredShadowsOuterBindingAndUnwinds() async throws {
        let outer = makeTrace()
        let inner = makeTrace()

        await ExecutionContext.$current.withValue(ExecutionContext(trace: outer)) {
            let seenInner = await ExecutionContext.withRestored(.init(trace: inner)) {
                ExecutionContext.current?.trace
            }
            XCTAssertEqual(seenInner, inner, "Inner binding must shadow the outer one")
            XCTAssertEqual(ExecutionContext.current?.trace, outer, "Outer binding must be restored")
        }
    }
}
