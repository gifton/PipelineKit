import XCTest
@testable import PipelineKit
@testable import PipelineKitCore

/// Verifies NextGuard's debug deinit diagnostics are error-exit aware (#97):
/// middleware that THROWS without calling next() is caller-visible and must
/// not warn; middleware that silently RETURNS without calling next() is the
/// dropped-chain bug class the warning exists for and must still warn.
final class NextGuardErrorExitTests: XCTestCase {
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
    }

    private final class EchoHandler: CommandHandler {
        typealias CommandType = TestCommand
        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            command.value
        }
    }

    private struct TestFailure: Error {}

    /// Throw-based short-circuit that deliberately does NOT conform to
    /// NextGuardWarningSuppressing — the chain builder detects the error
    /// exit on its own.
    private struct ThrowingMiddleware: Middleware {
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            throw TestFailure()
        }
    }

    /// Silently returns without calling next() and does NOT conform to
    /// NextGuardWarningSuppressing — the dropped-chain bug class. Only used
    /// with TestCommand, whose Result is String, so the cast always succeeds.
    private struct SwallowingMiddleware: Middleware {
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            // swiftlint:disable:next force_cast
            return "swallowed" as! T.Result
        }
    }

    /// Synchronous warning sink. NextGuard's deinit calls the handler
    /// synchronously and every guard is released before pipeline.execute
    /// returns, so assertions after the await are safe. (Deliberately NOT
    /// the async-actor pattern from PipelineKitCacheTests — that hop races
    /// the snapshot.)
    private final class WarningSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }
        var items: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private var sink: WarningSink!

    override func setUp() {
        super.setUp()
        sink = WarningSink()
        let sink = self.sink!
        NextGuardConfiguration.setWarningHandler { message in
            sink.add(message)
        }
        NextGuardConfiguration.shared.emitWarnings = true
    }

    override func tearDown() {
        NextGuardConfiguration.shared.warningHandler = nil
        NextGuardConfiguration.shared.emitWarnings = true
        sink = nil
        super.tearDown()
    }

    // MARK: - Unit level

    #if DEBUG
    func testUncalledGuardWarnsWithoutMark() {
        var nextGuard: NextGuard<TestCommand>? = NextGuard(
            { command, _ in command.value },
            identifier: "error-exit-unit-test"
        )
        XCTAssertNotNil(nextGuard)
        nextGuard = nil // deinit fires synchronously here
        XCTAssertEqual(sink.items.count, 1, "uncalled, unmarked guard must warn")
        XCTAssertTrue(sink.items.first?.contains("error-exit-unit-test") ?? false)
    }
    #endif

    func testMarkErrorExitSuppressesDeinitWarning() {
        var nextGuard: NextGuard<TestCommand>? = NextGuard(
            { command, _ in command.value },
            identifier: "error-exit-unit-test"
        )
        nextGuard?.markErrorExit()
        nextGuard = nil
        XCTAssertTrue(sink.items.isEmpty, "marked guard must not warn: \(sink.items)")
    }

    // MARK: - Chain level

    func testThrowingMiddlewareWithoutMarkerEmitsNoWarning() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(ThrowingMiddleware())

        do {
            _ = try await pipeline.execute(TestCommand(value: "x"), context: CommandContext())
            XCTFail("expected TestFailure")
        } catch is TestFailure {
            // expected: rejection propagates unchanged
        }

        XCTAssertTrue(
            sink.items.isEmpty,
            "error exits are caller-visible and must not warn: \(sink.items)"
        )
    }

    #if DEBUG
    func testSilentReturnWithoutMarkerStillWarns() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(SwallowingMiddleware())

        let result = try await pipeline.execute(TestCommand(value: "x"), context: CommandContext())
        XCTAssertEqual(result, "swallowed")

        XCTAssertEqual(
            sink.items.count, 1,
            "a silent return without next() is a dropped chain and must warn: \(sink.items)"
        )
        XCTAssertTrue(sink.items.first?.contains("SwallowingMiddleware") ?? false)
    }
    #endif

    /// Control: well-behaved middleware calling next() exactly once never warns.
    func testWellBehavedMiddlewareEmitsNoWarning() async throws {
        struct PassthroughMiddleware: Middleware {
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @escaping MiddlewareNext<T>
            ) async throws -> T.Result {
                try await next(command, context)
            }
        }
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(PassthroughMiddleware())
        let result = try await pipeline.execute(TestCommand(value: "ok"), context: CommandContext())
        XCTAssertEqual(result, "ok")
        XCTAssertTrue(sink.items.isEmpty)
    }
}
