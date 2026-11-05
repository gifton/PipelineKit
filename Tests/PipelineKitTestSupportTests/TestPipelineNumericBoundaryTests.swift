import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TestPipelineNumericBoundaryTests: XCTestCase {
    private static let invalidIntervals: [TimeInterval] = [
        -1, -.infinity, .infinity, .nan, .greatestFiniteMagnitude,
        Double(UInt64.max) / 1_000_000_000
    ]

    func testEveryTestPipelineSleepEntryRejectsUnrepresentableIntervals() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: NumericContractHandler(), middleware: [NumericContractMiddleware()]
        )
        for interval in Self.invalidIntervals {
            do {
                try await pipeline.delayMiddleware(NumericContractMiddleware.self, delay: interval)
                XCTFail("Middleware delay accepted invalid interval \(interval)")
            } catch TestPipelineError.invalidDelay { }
            do {
                try await PipelineTestUtils.timeTravel(seconds: interval)
                XCTFail("timeTravel accepted invalid interval \(interval)")
            } catch TestPipelineError.invalidDelay { }
            // NaN cannot form an ordered ClosedRange; the point-range fixtures
            // exercise every remaining invalid endpoint through ChaosMonkey.
            if !interval.isNaN {
                let chaos = ChaosMonkey()
                await chaos.enable(failureRate: 0, delayRange: interval...interval)
                do {
                    try await chaos.maybeInjectChaos()
                    XCTFail("Chaos delay accepted invalid interval \(interval)")
                } catch TestPipelineError.invalidDelay { }
            }
        }
    }

    func testRepresentableDelaysAndExtremeFailureCountsDoNotTrap() async throws {
        let pipeline = try await PipelineTestUtils.createTestPipeline(
            handler: NumericContractHandler(), middleware: [NumericContractMiddleware()]
        )
        let maximum = (Double(UInt64.max) / 1_000_000_000).nextDown
        for interval: TimeInterval in [0, .leastNonzeroMagnitude, 0.000_000_001, maximum] {
            try await pipeline.delayMiddleware(NumericContractMiddleware.self, delay: interval)
        }
        try await pipeline.delayMiddleware(NumericContractMiddleware.self, delay: 0)
        try await pipeline.failMiddleware(NumericContractMiddleware.self, after: .max)
        let result = try await pipeline.execute(NumericContractCommand())
        XCTAssertEqual(result, 1)
        for count in [-1, Int.min] {
            do {
                try await pipeline.failMiddleware(NumericContractMiddleware.self, after: count)
                XCTFail("Negative failure threshold must be rejected")
            } catch TestPipelineError.invalidFailureCount { }
        }
        try await PipelineTestUtils.timeTravel(seconds: 0)
        try await PipelineTestUtils.timeTravel(seconds: .leastNonzeroMagnitude)
    }

    func testChaosRejectsInvalidFailureRatesWithoutStartingADelay() async {
        for rate: Double in [-1, 1.1, -.infinity, .infinity, .nan] {
            let chaos = ChaosMonkey()
            await chaos.enable(failureRate: rate, delayRange: 60...60)
            do {
                try await chaos.maybeInjectChaos()
                XCTFail("Invalid chaos probability must be rejected")
            } catch ChaosError.invalidFailureRate {
            } catch {
                XCTFail("Unexpected chaos error: \(error)")
            }
        }
    }
}

private struct NumericContractCommand: Command { typealias Result = Int }
private struct NumericContractHandler: CommandHandler {
    func handle(_ command: NumericContractCommand, context: CommandContext) async throws -> Int { 1 }
}
private struct NumericContractMiddleware: Middleware {
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await next(command, context)
    }
}
