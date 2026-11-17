import Synchronization
import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TestPipelineWarningContractTests: XCTestCase {
    func testUnmockedOriginalRejectsConcurrentNextCallsAndSettlesBothTasks() async throws {
        let release = TestSynchronizer()
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: WarningConcurrentHandler(release: release),
            middleware: [WarningConcurrentMiddleware(release: release)]
        )
        do {
            _ = try await pipeline.execute(WarningContractCommand())
            XCTFail("Concurrent next calls must remain guarded")
        } catch PipelineError.nextCurrentlyExecuting { }
    }

    func testMissingNextWarningMatrixPreservesOriginalMiddlewareDiagnostics() async throws {
        let previousHandler = NextGuardConfiguration.shared.warningHandler
        let previousEnabled = NextGuardConfiguration.shared.emitWarnings
        let warnings = Mutex<[String]>([])
        NextGuardConfiguration.setWarningHandler { message in warnings.withLock { $0.append(message) } }
        defer {
            NextGuardConfiguration.shared.warningHandler = previousHandler
            NextGuardConfiguration.shared.emitWarnings = previousEnabled
        }
        let cases: [(name: String, middleware: any Middleware, setting: Int, warns: Bool)] = [
            ("ordinary silent return", WarningOrdinaryMiddleware(), 0, true),
            ("explicit suppression", WarningSuppressedMiddleware(), 0, false),
            ("unsafe opt-out", WarningUnsafeMiddleware(), 0, false),
            ("original throw", WarningThrowingMiddleware(), 0, false),
            ("configured mock", WarningOrdinaryMiddleware(), 1, false),
            ("injected failure", WarningOrdinaryMiddleware(), 2, false)
        ]
        for fixture in cases {
            warnings.withLock { $0.removeAll() }
            let pipeline = try await PipelineTestUtils.createTestPipeline(
                handler: WarningContractHandler(), middleware: [fixture.middleware]
            )
            if fixture.setting == 1 {
                try await pipeline.mockMiddleware(WarningOrdinaryMiddleware.self, for: WarningContractCommand.self) { _ in "mock" }
            } else if fixture.setting == 2 {
                try await pipeline.failMiddleware(WarningOrdinaryMiddleware.self, after: 0)
            }
            do {
                _ = try await pipeline.execute(WarningContractCommand())
            } catch WarningContractError.expected {
            } catch TestPipelineError.injectedFailure { }
            let captured = warnings.withLock { $0 }
            #if DEBUG
            XCTAssertEqual(captured.count, fixture.warns ? 1 : 0, fixture.name)
            #else
            XCTAssertTrue(captured.isEmpty, "Release builds do not emit NextGuard deinit warnings")
            #endif
        }
    }
}

private struct WarningContractCommand: Command { typealias Result = String }
private enum WarningContractError: Error { case expected, unexpectedCommand, missingConcurrentGuard }
private struct WarningContractHandler: CommandHandler {
    func handle(_ command: WarningContractCommand, context: CommandContext) async throws -> String { "handler" }
}
private struct WarningOrdinaryMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        guard let result = "silent return" as? T.Result else { throw WarningContractError.unexpectedCommand }
        return result
    }
}
private struct WarningSuppressedMiddleware: NextGuardWarningSuppressing {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await WarningOrdinaryMiddleware().execute(command, context: context, next: next)
    }
}
private struct WarningUnsafeMiddleware: UnsafeMiddleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await WarningOrdinaryMiddleware().execute(command, context: context, next: next)
    }
}
private struct WarningThrowingMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        throw WarningContractError.expected
    }
}

private struct WarningConcurrentHandler: CommandHandler {
    let release: TestSynchronizer
    func handle(_ command: WarningContractCommand, context: CommandContext) async throws -> String {
        try await release.waitForSignal("release")
        return "handler"
    }
}

private struct WarningConcurrentMiddleware: Middleware {
    let release: TestSynchronizer
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await withThrowingTaskGroup(of: T.Result.self) { group in
            for _ in 0..<2 { group.addTask { try await next(command, context) } }
            group.addTask {
                // Hang detector only. It races the two calls above, so it must be
                // far longer than any scheduling stall (it was 1s).
                try await Task.sleep(for: .seconds(10))
                await release.signal("release")
                throw WarningContractError.missingConcurrentGuard
            }
            do {
                guard let result = try await group.next() else { throw WarningContractError.unexpectedCommand }
                group.cancelAll()
                return result
            } catch {
                await release.signal("release")
                group.cancelAll()
                throw error
            }
        }
    }
}
