import XCTest
import Synchronization
@testable import PipelineKit
import PipelineKitCore
import PipelineKitResilience

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testThrowBasedResilienceMiddlewaresDoNotSuppressNextGuardWarnings() {
        XCTAssertFalse(BackPressureMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(CircuitBreakerMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(RateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(EnhancedRateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(PartitionedBulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(HealthCheckMiddleware.self is any NextGuardWarningSuppressing.Type)
    }

    func testBulkheadSuccessfulShortCircuitsAndErrorControlsThroughGuardedChains() async throws {
        let warnings = BulkheadWarningSink()
        let previousHandler = NextGuardConfiguration.shared.warningHandler
        let previousEnabled = NextGuardConfiguration.shared.emitWarnings
        NextGuardConfiguration.setWarningHandler { warnings.add($0) }
        defer {
            NextGuardConfiguration.shared.warningHandler = previousHandler
            NextGuardConfiguration.shared.emitWarnings = previousEnabled
        }

        for route in BulkheadGuardRoute.allCases {
            for scenario in BulkheadRejectionScenario.allCases {
                let ledger = BulkheadHandlerLedger()
                let middleware = BulkheadMiddleware(configuration: .init(
                    maxConcurrency: 1, rejectionPolicy: scenario.policy
                ))
                let chain = try await route.chain(middleware, ledger: ledger)
                let holder = Task { @concurrent in
                    try await chain(AdmissionCommand(id: "holder"), CommandContext())
                }
                while !(await ledger.entered("holder")) { await Task.yield() }

                do {
                    let result = try await chain(AdmissionCommand(id: "overflow"), CommandContext())
                    XCTAssertTrue(scenario.succeeds, "\(route), \(scenario)")
                    XCTAssertEqual(result, "fallback")
                } catch BulkheadFixtureError.expected {
                    XCTAssertEqual(scenario, .customError)
                } catch PipelineError.middlewareError(let middleware, let message, _) {
                    XCTAssertFalse(scenario.succeeds)
                    XCTAssertEqual(middleware, "BulkheadMiddleware")
                    XCTAssertTrue(message.contains("failed to provide valid result"))
                } catch {
                    XCTFail("Unexpected \(route), \(scenario): \(error)")
                }
                await ledger.release("holder")
                let result = try await holder.value
                XCTAssertEqual(result, "holder")
                let entries = await ledger.entries
                XCTAssertEqual(entries, ["holder"], "Fallback must not enter the handler")
                XCTAssertTrue(warnings.take().isEmpty, "\(route), \(scenario) must not warn")
            }

            let ledger = BulkheadHandlerLedger()
            let chain = try await route.chain(AccidentallyDroppedBulkheadChain(), ledger: ledger)
            let result = try await chain(AdmissionCommand(id: "dropped"), CommandContext())
            XCTAssertEqual(result, "dropped")
            let captured = warnings.take()
            #if DEBUG
            XCTAssertEqual(captured.count, 1, "\(route): \(captured)")
            XCTAssertTrue(captured.first?.contains("AccidentallyDroppedBulkheadChain") == true)
            #else
            XCTAssertTrue(captured.isEmpty)
            #endif
        }
    }
}

private enum BulkheadRejectionScenario: CaseIterable {
    case fallback, custom, fallbackWrongType, customWrongType, customError

    var succeeds: Bool { self == .fallback || self == .custom }
    var policy: BulkheadMiddleware.RejectionPolicy {
        switch self {
        case .fallback: .fallback(value: { "fallback" })
        case .custom: .custom(handler: { _ in "fallback" })
        case .fallbackWrongType: .fallback(value: { 17 })
        case .customWrongType: .custom(handler: { _ in 17 })
        case .customError: .custom(handler: { _ in throw BulkheadFixtureError.expected })
        }
    }
}

private enum BulkheadGuardRoute: CaseIterable {
    case array, contiguousArray, builder

    func chain(
        _ middleware: any Middleware,
        ledger: BulkheadHandlerLedger
    ) async throws -> @Sendable (AdmissionCommand, CommandContext) async throws -> String {
        let handler = BulkheadGuardHandler(ledger: ledger)
        switch self {
        case .array:
            return MiddlewareChainBuilder.build(middlewares: [middleware], insertCancellationChecks: true) {
                try await handler.handle($0, context: $1)
            }
        case .contiguousArray:
            return MiddlewareChainBuilder.build(middlewares: ContiguousArray([middleware]), insertCancellationChecks: true) {
                try await handler.handle($0, context: $1)
            }
        case .builder:
            let builder = PipelineBuilder(handler: handler)
            await builder.with(middleware)
            let pipeline = try await builder.build()
            return { try await pipeline.execute($0, context: $1) }
        }
    }
}

private struct BulkheadGuardHandler: CommandHandler {
    let ledger: BulkheadHandlerLedger
    func handle(_ command: AdmissionCommand, context: CommandContext) async throws -> String {
        try await ledger.run(command.id, fails: false)
    }
}

private struct AccidentallyDroppedBulkheadChain: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        guard let result = "dropped" as? T.Result else { throw BulkheadFixtureError.expected }
        return result
    }
}

private final class BulkheadWarningSink: Sendable {
    private let values = Mutex<[String]>([])
    func add(_ message: String) { values.withLock { $0.append(message) } }
    func take() -> [String] { values.withLock { let result = $0; $0 = []; return result } }
}
