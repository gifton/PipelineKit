import XCTest
import PipelineKit
import PipelineKitCore

final class PipelineCancellationBoundaryTests: XCTestCase {
    private struct BoundaryCommand: Command {
        typealias Result = Int
        let cancel: Bool
    }

    private enum Failure: Sendable { case none, native, explicitCancellation, cancelledDomain }
    private enum DomainFailure: Error { case failed }

    private struct BoundaryHandler: CommandHandler {
        let failure: Failure

        func handle(_ command: BoundaryCommand, context: CommandContext) async throws -> Int {
            context.setMetadata("handlerReached", value: true)
            switch failure {
            case .none: return 42
            case .native: throw CancellationError()
            case .explicitCancellation: throw PipelineError.cancelled(context: "handler detail")
            case .cancelledDomain:
                withUnsafeCurrentTask { $0?.cancel() }
                throw DomainFailure.failed
            }
        }
    }

    private struct BoundaryMiddleware: Middleware {
        let cancels: Bool
        let marker: String

        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            context.setMetadata(marker, value: true)
            if cancels, (command as? BoundaryCommand)?.cancel == true {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return try await next(command, context)
        }
    }

    private struct CancellingInterceptor: CommandInterceptor {
        func intercept<T: Command>(_ command: T) -> T {
            if (command as? BoundaryCommand)?.cancel == true {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return command
        }
    }

    private enum Variant: CaseIterable {
        case standard, erased, dynamic
    }

    private func makeExecution(
        _ variant: Variant,
        middlewares: [any Middleware],
        failure: Failure = .none
    ) async throws -> @Sendable (BoundaryCommand, CommandContext) async throws -> Int {
        switch variant {
        case .standard:
            let pipeline = StandardPipeline(handler: BoundaryHandler(failure: failure))
            try await pipeline.addMiddlewares(middlewares)
            return { try await pipeline.execute($0, context: $1) }
        case .erased:
            let pipeline = AnyStandardPipeline(handler: BoundaryHandler(failure: failure))
            for middleware in middlewares { try await pipeline.addMiddleware(middleware) }
            return { try await pipeline.execute($0, context: $1) }
        case .dynamic:
            let pipeline = DynamicPipeline()
            await pipeline.register(BoundaryCommand.self, handler: BoundaryHandler(failure: failure))
            try await pipeline.addMiddlewares(middlewares)
            return { try await pipeline.send($0, context: $1, retryPolicy: .none) }
        }
    }

    private func assertCancellation(
        _ task: Task<Int, any Error>,
        variant: Variant,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        switch await task.result {
        case .success:
            XCTFail("Cancelled execution completed: \(variant)", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true,
                          "Expected PipelineError.cancelled for \(variant): \(error)", file: file, line: line)
        }
    }

    // Removing entry cancellation checks would allow the handler to run.
    func testPreCancelledExecutionDoesNotReachEmptyChainHandler() async throws {
        for variant in Variant.allCases {
            for warm in [false, true] {
                let execute = try await makeExecution(variant, middlewares: [])
                if warm { _ = try await execute(BoundaryCommand(cancel: false), CommandContext()) }
                let context = CommandContext()
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await execute(BoundaryCommand(cancel: false), context)
                }
                await assertCancellation(task, variant: variant)
                XCTAssertNil(context.getMetadata("handlerReached"), "\(variant), warm=\(warm)")
                XCTAssertEqual(context.getCancellationReason(), .userCancellation, "\(variant), warm=\(warm)")
            }
        }
    }

    // Missing checks between cached middleware closures would run the second middleware.
    func testCancellationBetweenMiddlewareStopsColdAndCachedChains() async throws {
        for variant in Variant.allCases {
            for warm in [false, true] {
                let execute = try await makeExecution(variant, middlewares: [
                    BoundaryMiddleware(cancels: true, marker: "firstReached"),
                    BoundaryMiddleware(cancels: false, marker: "secondReached")
                ])
                if warm { _ = try await execute(BoundaryCommand(cancel: false), CommandContext()) }
                let context = CommandContext()
                let task = Task { try await execute(BoundaryCommand(cancel: true), context) }
                await assertCancellation(task, variant: variant)
                XCTAssertEqual(context.getMetadata("firstReached") as? Bool, true)
                XCTAssertNil(context.getMetadata("secondReached"), "\(variant), warm=\(warm)")
                XCTAssertNil(context.getMetadata("handlerReached"), "\(variant), warm=\(warm)")
                XCTAssertEqual(context.getCancellationReason(), .userCancellation)
            }
        }
    }

    // Missing the final handler checkpoint would admit cancelled work after the last middleware.
    func testCancellationInLastMiddlewareStopsColdAndCachedHandlers() async throws {
        for variant in Variant.allCases {
            for warm in [false, true] {
                let execute = try await makeExecution(variant, middlewares: [
                    BoundaryMiddleware(cancels: true, marker: "lastReached")
                ])
                if warm { _ = try await execute(BoundaryCommand(cancel: false), CommandContext()) }
                let context = CommandContext()
                context.markAsCancelled(reason: .timeout(duration: 5, gracePeriod: nil))
                let task = Task { try await execute(BoundaryCommand(cancel: true), context) }
                await assertCancellation(task, variant: variant)
                XCTAssertNil(context.getMetadata("handlerReached"), "\(variant), warm=\(warm)")
                XCTAssertEqual(context.getCancellationReason(), .timeout(duration: 5, gracePeriod: nil))
            }
        }
    }

    // Reusing diagnostic metadata must not reject a live task.
    func testRecordedCancellationReasonDoesNotCancelLiveTask() async throws {
        for variant in Variant.allCases {
            let execute = try await makeExecution(variant, middlewares: [])
            let context = CommandContext()
            context.markAsCancelled(reason: .custom("prior execution"))
            let result = try await execute(BoundaryCommand(cancel: false), context)
            XCTAssertEqual(result, 42)
            XCTAssertEqual(context.getCancellationReason(), .custom("prior execution"))
        }
    }

    // Native cancellation from user code is normalized at the public pipeline boundary.
    func testNativeHandlerCancellationIsNormalizedWithoutTaskCancellation() async throws {
        for variant in Variant.allCases {
            let execute = try await makeExecution(variant, middlewares: [], failure: .native)
            let context = CommandContext()
            await assertCancellation(Task { try await execute(BoundaryCommand(cancel: false), context) }, variant: variant)
            XCTAssertEqual(context.getCancellationReason(), .userCancellation)
        }
    }

    func testExplicitCancellationPreservesErrorDetailAndSpecificContextReason() async throws {
        for variant in Variant.allCases {
            let execute = try await makeExecution(variant, middlewares: [], failure: .explicitCancellation)
            let context = CommandContext()
            context.markAsCancelled(reason: .systemShutdown)
            do {
                _ = try await execute(BoundaryCommand(cancel: false), context)
                XCTFail("Expected cancellation for \(variant)")
            } catch let error as PipelineError {
                guard case .cancelled(let detail) = error else { return XCTFail("Unexpected \(error)") }
                XCTAssertEqual(detail, "handler detail")
            }
            XCTAssertEqual(context.getCancellationReason(), .systemShutdown)
        }
    }

    // A cancelled task can still report a real domain failure; its identity must survive.
    func testCancellationFlagDoesNotMaskDomainFailure() async throws {
        for variant in Variant.allCases {
            let execute = try await makeExecution(variant, middlewares: [], failure: .cancelledDomain)
            let context = CommandContext()
            let task = Task { try await execute(BoundaryCommand(cancel: false), context) }
            switch await task.result {
            case .success: XCTFail("Expected domain failure for \(variant)")
            case .failure(let error): XCTAssertTrue(error is DomainFailure, "\(variant): \(error)")
            }
            XCTAssertNil(context.getCancellationReason())
        }
    }


    // Entry checks precede synchronous interceptors; the empty-chain handler still needs a checkpoint.
    func testInterceptorCancellationStopsHandlerWithoutMiddleware() async throws {
        let standard = StandardPipeline(handler: BoundaryHandler(failure: .none))
        await standard.addInterceptor(CancellingInterceptor())
        let erased = AnyStandardPipeline(handler: BoundaryHandler(failure: .none))
        await erased.addInterceptor(CancellingInterceptor())
        let executions: [(Variant, @Sendable (BoundaryCommand, CommandContext) async throws -> Int)] = [
            (.standard, { try await standard.execute($0, context: $1) }),
            (.erased, { try await erased.execute($0, context: $1) })
        ]
        for (variant, execute) in executions {
            _ = try await execute(BoundaryCommand(cancel: false), CommandContext())
            let context = CommandContext()
            let task = Task { try await execute(BoundaryCommand(cancel: true), context) }
            await assertCancellation(task, variant: variant)
            XCTAssertNil(context.getMetadata("handlerReached"), "\(variant)")
            XCTAssertEqual(context.getCancellationReason(), .userCancellation)
        }
    }

}
