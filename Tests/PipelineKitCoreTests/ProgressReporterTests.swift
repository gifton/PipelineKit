import XCTest
@testable import PipelineKitCore

final class ProgressReporterTests: XCTestCase {
    func testUpdatesDeliveredInOrder() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        reporter.report(fraction: 0.25, message: "a")
        reporter.report(fraction: 0.5, message: "b")
        reporter.finish()

        var received: [ProgressUpdate] = []
        for await update in stream { received.append(update) }

        XCTAssertEqual(received.map(\.message), ["a", "b"])
        XCTAssertEqual(received.map(\.fraction), [0.25, 0.5])
    }

    func testReportAfterFinishIsANoOp() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        reporter.report(message: "before")
        reporter.finish()
        reporter.report(message: "after") // must be dropped silently

        var received: [String?] = []
        for await update in stream { received.append(update.message) }

        XCTAssertEqual(received, ["before"])
    }

    func testFinishIsIdempotent() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        reporter.finish()
        reporter.finish() // second finish must not crash or hang

        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testDropOldestWhenBufferOverflows() async {
        // No consumer attached while reporting: buffer of 2 must retain only
        // the NEWEST two updates (bounded, drop-oldest per the spec).
        let (stream, reporter) = ProgressReporter.makeStream(bufferSize: 2)
        for i in 0..<5 { reporter.report(message: "u\(i)") }
        reporter.finish()

        var received: [String?] = []
        for await update in stream { received.append(update.message) }

        XCTAssertEqual(received, ["u3", "u4"], "Bounded buffer must keep only the newest updates")
    }

    func testReportingNeverBlocksWithoutConsumer() {
        let (stream, reporter) = ProgressReporter.makeStream(bufferSize: 1)
        for i in 0..<1_000 { reporter.report(fraction: Double(i) / 1_000) }
        // Reaching this line without deadlock IS the assertion.
        reporter.finish()
        _ = stream
    }

    func testProgressReporterContextKeyRoundTrips() {
        let (stream, reporter) = ProgressReporter.makeStream()
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter
        XCTAssertNotNil(context[ContextKeys.progressReporter])
        reporter.finish()
        _ = stream
    }
}
