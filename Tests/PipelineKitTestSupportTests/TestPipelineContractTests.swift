import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TestPipelineContractTests: XCTestCase {
    func testTypedMockReceivesCommandAndSkipsOriginalMiddlewareAndHandler() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [ContractMiddleware()]
        )
        try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { command in
            "mocked \(command.value)"
        }
        let context = CommandContext()
        let result = try await pipeline.execute(ContractCommand(value: "input"), context: context)
        XCTAssertEqual(result, "mocked input")
        XCTAssertNil(context.getMetadata("original middleware"))
        XCTAssertNil(context.getMetadata("original handler"))
        let recorder = await pipeline.getRecorder()
        let middlewareRecords = await recorder.getMiddlewareExecutions()
        XCTAssertEqual(middlewareRecords.count, 1)
        XCTAssertEqual(middlewareRecords.first?.succeeded, true)
    }

    func testConfiguredFailureReachesTheWrappedMiddleware() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [ContractMiddleware()]
        )
        try await pipeline.failMiddleware(ContractMiddleware.self, after: 0)
        do {
            _ = try await pipeline.execute(ContractCommand())
            XCTFail("A configured middleware failure must not be ignored")
        } catch {
            XCTAssertTrue(error is TestPipelineError)
        }
    }

    func testResetSettlesEachInFlightRecordInItsOriginalRecorder() async throws {
        for shouldFail in [false, true] {
            let entered = expectation(description: "Base pipeline entered")
            let release = TestSynchronizer()
            let base = StandardPipeline(handler: SuspendedContractHandler(
                entered: entered, release: release, shouldFail: shouldFail
            ))
            let pipeline = TestPipeline(basePipeline: base)
            let original = await pipeline.getRecorder()
            let execution = Task { try await pipeline.execute(ContractCommand()) }
            await fulfillment(of: [entered], timeout: 2)
            await pipeline.reset()
            let replacement = await pipeline.getRecorder()
            await release.signal("release")
            do {
                _ = try await execution.value
                XCTAssertFalse(shouldFail)
            } catch {
                XCTAssertTrue(shouldFail)
                XCTAssertTrue(error is ContractFailure)
            }
            let originalRecords = await original.getExecutions()
            let replacementRecords = await replacement.getExecutions()
            XCTAssertEqual(originalRecords.count, 1)
            XCTAssertNotNil(originalRecords.first?.endTime, "Reset must not strand an admitted execution")
            XCTAssertEqual(originalRecords.first?.error != nil, shouldFail)
            XCTAssertTrue(replacementRecords.isEmpty)
        }
    }

    func testRecordingOnlyPipelineRejectsEveryInterceptionSetting() async {
        let pipeline = TestPipeline(basePipeline: StandardPipeline(handler: ContractHandler()))
        for setting in 0..<3 {
            do {
                switch setting {
                case 0: try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { _ in "mock" }
                case 1: try await pipeline.delayMiddleware(ContractMiddleware.self, delay: 0)
                default: try await pipeline.failMiddleware(ContractMiddleware.self, after: 0)
                }
                XCTFail("Opaque middleware must not silently accept configuration")
            } catch TestPipelineError.interceptionUnavailable {
            } catch {
                XCTFail("Unexpected configuration error: \(error)")
            }
        }
    }

    func testFactoryRejectsUnknownMiddlewareAndWrongCommandType() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [ContractMiddleware()]
        )
        do {
            try await pipeline.delayMiddleware(DisabledContractMiddleware.self, delay: 0)
            XCTFail("Unknown middleware must be rejected")
        } catch TestPipelineError.middlewareNotFound { }
        do {
            try await pipeline.mockMiddleware(ContractMiddleware.self, for: OtherContractCommand.self) { _ in 42 }
            XCTFail("A different command/result pair must be rejected")
        } catch TestPipelineError.commandTypeMismatch { }
        let result = try await pipeline.execute(ContractCommand())
        XCTAssertEqual(result, "handler")
    }

    func testFailureCountdownIsSharedByConcurrentEntriesAndResetClearsIt() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [ContractMiddleware()]
        )
        try await pipeline.failMiddleware(ContractMiddleware.self, after: 7)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    do {
                        _ = try await pipeline.execute(ContractCommand())
                        return true
                    } catch TestPipelineError.injectedFailure {
                        return false
                    } catch {
                        XCTFail("Unexpected execution error: \(error)")
                        return false
                    }
                }
            }
            var successful = 0
            for await succeeded in group where succeeded { successful += 1 }
            return successful
        }
        XCTAssertEqual(successes, 7)
        await pipeline.reset()
        let resetResult = try await pipeline.execute(ContractCommand())
        XCTAssertEqual(resetResult, "handler")
    }

    func testInactiveConditionalMiddlewareDoesNotConsumeItsConfiguredFailure() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [DisabledContractMiddleware()]
        )
        try await pipeline.failMiddleware(DisabledContractMiddleware.self, after: 0)
        let result = try await pipeline.execute(ContractCommand())
        XCTAssertEqual(result, "handler")
        let recorder = await pipeline.getRecorder()
        let middlewareRecords = await recorder.getMiddlewareExecutions()
        XCTAssertTrue(middlewareRecords.isEmpty)
    }

    func testOrdinaryMiddlewareRetainsNextGuard() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [DoubleNextContractMiddleware()]
        )
        do {
            _ = try await pipeline.execute(ContractCommand())
            XCTFail("A second next call must remain guarded")
        } catch PipelineError.nextAlreadyCalled { }
    }

    func testUnsafeRetryCanReenterWrappedOrdinaryMiddleware() async throws {
        let handler = FlakyContractHandler()
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: handler, middleware: [RetryContractMiddleware(), ContractMiddleware()]
        )
        let result = try await pipeline.execute(ContractCommand())
        XCTAssertEqual(result, "recovered")
        let attempts = await handler.attempts
        XCTAssertEqual(attempts, 2)
        let recorder = await pipeline.getRecorder()
        let records = await recorder.getMiddlewareExecutions()
        XCTAssertEqual(records.map(\.succeeded), [false, true, true])
    }

    func testDetachedNextRetainsInterceptionForOrdinaryAndUnsafeMiddleware() async throws {
        let forwarding: [any Middleware] = [DetachedContractMiddleware(), UnsafeDetachedContractMiddleware()]
        for middleware in forwarding {
            let pipeline = try await PipelineTestUtils.createTestPipeline(
                handler: ContractHandler(), middleware: [middleware, ContractMiddleware()]
            )
            try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { _ in "detached mock" }
            let result = try await pipeline.execute(ContractCommand())
            XCTAssertEqual(result, "detached mock")
        }
    }

    func testNextRestoresItsOwningSessionWhenCalledInsideAnotherTestPipeline() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [NestedContractMiddleware(), ContractMiddleware()]
        )
        try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { _ in "outer mock" }
        let result = try await pipeline.execute(ContractCommand())
        XCTAssertEqual(result, "outer mock")
    }

    func testResetPreservesSettingsForAnAlreadyAdmittedExecution() async throws {
        let entered = expectation(description: "Execution reached its initial gate")
        let release = TestSynchronizer()
        let gate = ContractAdmissionGate(entered: entered, release: release)
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [GateContractMiddleware(gate: gate), ContractMiddleware()]
        )
        try await pipeline.failMiddleware(ContractMiddleware.self, after: 0)
        let originalRecorder = await pipeline.getRecorder()
        let execution = Task { try await pipeline.execute(ContractCommand()) }
        await fulfillment(of: [entered], timeout: 2)
        await pipeline.reset()
        try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { _ in "new settings" }
        await release.signal("release")
        do {
            _ = try await execution.value
            XCTFail("In-flight work must retain its admitted failure setting")
        } catch TestPipelineError.injectedFailure { }
        let newResult = try await pipeline.execute(ContractCommand())
        XCTAssertEqual(newResult, "new settings")
        let oldRecords = await originalRecorder.getExecutions()
        XCTAssertEqual(oldRecords.count, 1)
        XCTAssertNotNil(oldRecords.first?.endTime)
    }

    func testCancelledDelayPreventsOriginalMiddlewareAndSettlesRecording() async throws {
        let entered = expectation(description: "The middleware before the delay entered")
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [SignalContractMiddleware(entered: entered), ContractMiddleware()]
        )
        try await pipeline.delayMiddleware(ContractMiddleware.self, delay: 60)
        let context = CommandContext()
        let execution = Task { try await pipeline.execute(ContractCommand(), context: context) }
        await fulfillment(of: [entered], timeout: 2)
        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("Expected cancellation")
        } catch PipelineError.cancelled { }
        XCTAssertNil(context.getMetadata("original middleware"))
        let recorder = await pipeline.getRecorder()
        let records = await recorder.getExecutions()
        XCTAssertNotNil(records.first?.endTime)
        XCTAssertNotNil(records.first?.error)
    }

    func testCancelledMockSettlesBeforeExecutionReturns() async throws {
        let entered = expectation(description: "Mock entered")
        let settled = TestSynchronizer()
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [ContractMiddleware()]
        )
        try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { _ in
            entered.fulfill()
            do { try await Task.sleep(for: .seconds(60)) } catch { }
            await settled.signal("settled")
            return "ignored cancellation"
        }
        let execution = Task { try await pipeline.execute(ContractCommand()) }
        await fulfillment(of: [entered], timeout: 2)
        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("A mock that returns after cancellation must not report success")
        } catch PipelineError.cancelled { }
        let didSettle = await settled.isSignaled("settled")
        XCTAssertTrue(didSettle)
        let recorder = await pipeline.getRecorder()
        let records = await recorder.getMiddlewareExecutions()
        XCTAssertEqual(records.map(\.succeeded), [false])
    }

    func testCancelledAdmissionDoesNotStartMock() async throws {
        let started = TestSynchronizer()
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: ContractHandler(), middleware: [ContractMiddleware()]
        )
        try await pipeline.mockMiddleware(ContractMiddleware.self, for: ContractCommand.self) { _ in
            await started.signal("started")
            return "mock"
        }
        let execution = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.execute(ContractCommand())
        }
        do {
            _ = try await execution.value
            XCTFail("Expected cancelled admission")
        } catch PipelineError.cancelled { }
        let didStart = await started.isSignaled("started")
        XCTAssertFalse(didStart)
    }
}

private struct ContractCommand: Command {
    typealias Result = String
    var value = "input"
}
private struct OtherContractCommand: Command { typealias Result = Int }
private enum ContractFailure: Error { case expected }

private struct ContractHandler: CommandHandler {
    func handle(_ command: ContractCommand, context: CommandContext) async throws -> String {
        context.setMetadata("original handler", value: true)
        return "handler"
    }
}

private struct SuspendedContractHandler: CommandHandler {
    let entered: XCTestExpectation
    let release: TestSynchronizer
    let shouldFail: Bool

    func handle(_ command: ContractCommand, context: CommandContext) async throws -> String {
        entered.fulfill()
        try await release.waitForSignal("release")
        if shouldFail { throw ContractFailure.expected }
        return "handler"
    }
}

private struct ContractMiddleware: Middleware {
    let priority: ExecutionPriority = .processing
    func execute<T: Command>(
        _ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        context.setMetadata("original middleware", value: true)
        return try await next(command, context)
    }
}

private struct DisabledContractMiddleware: ConditionalMiddleware {
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool { false }
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        XCTFail("Inactive middleware must not execute")
        return try await next(command, context)
    }
}

private struct DoubleNextContractMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        _ = try await next(command, context)
        return try await next(command, context)
    }
}

private struct RetryContractMiddleware: UnsafeMiddleware {
    let priority: ExecutionPriority = .resilience
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        do { return try await next(command, context) } catch ContractFailure.expected {
            return try await next(command, context)
        }
    }
}

private actor FlakyContractHandler: CommandHandler {
    private(set) var attempts = 0
    func handle(_ command: ContractCommand, context: CommandContext) async throws -> String {
        attempts += 1
        if attempts == 1 { throw ContractFailure.expected }
        return "recovered"
    }
}

private actor ContractAdmissionGate {
    let entered: XCTestExpectation
    let release: TestSynchronizer
    private var firstEntry = true
    init(entered: XCTestExpectation, release: TestSynchronizer) {
        self.entered = entered
        self.release = release
    }
    func holdFirstEntry() async throws {
        guard firstEntry else { return }
        firstEntry = false
        entered.fulfill()
        try await release.waitForSignal("release")
    }
}

private struct GateContractMiddleware: Middleware {
    let priority: ExecutionPriority = .authentication
    let gate: ContractAdmissionGate
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await gate.holdFirstEntry()
        return try await next(command, context)
    }
}

private struct SignalContractMiddleware: Middleware {
    let priority: ExecutionPriority = .authentication
    let entered: XCTestExpectation
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        entered.fulfill()
        return try await next(command, context)
    }
}

private struct DetachedContractMiddleware: Middleware {
    let priority: ExecutionPriority = .authentication
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await Task.detached { try await next(command, context) }.value
    }
}

private struct UnsafeDetachedContractMiddleware: UnsafeMiddleware {
    let priority: ExecutionPriority = .authentication
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await Task.detached { try await next(command, context) }.value
    }
}

private struct NestedContractMiddleware: Middleware {
    let priority: ExecutionPriority = .authentication
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        let inner = try await PipelineTestUtils.createTestPipeline(
            handler: NestedContractHandler<T.Result>(), middleware: [ContractMiddleware()]
        )
        return try await inner.execute(NestedContractCommand { try await next(command, context) })
    }
}

private struct NestedContractCommand<Value: Sendable>: Command {
    typealias Result = Value
    let forward: @Sendable () async throws -> Value
}

private struct NestedContractHandler<Value: Sendable>: CommandHandler {
    func handle(_ command: NestedContractCommand<Value>, context: CommandContext) async throws -> Value {
        try await command.forward()
    }
}
