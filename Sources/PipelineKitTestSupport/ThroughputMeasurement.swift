import Foundation

package enum ThroughputMeasurement {
    package enum Failure: Error, Equatable {
        case invalidConfiguration
        case mismatchedResults(expected: Int, actual: Int)
        case invalidDuration
        case zeroDurationExhausted
        case invalidRate
    }

    package static func measure(
        iterations initialIterations: Int,
        maxAttempts: Int = 8,
        duration: (ContinuousClock.Instant, ContinuousClock.Instant) -> Double = { start, end in
            let components = start.duration(to: end).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        },
        workload: (Int) async throws -> Int
    ) async throws -> Double {
        guard initialIterations > 0, maxAttempts > 0 else { throw Failure.invalidConfiguration }
        let clock = ContinuousClock()
        var iterations = initialIterations
        for attempt in 0..<maxAttempts {
            let start = clock.now
            let matches = try await workload(iterations)
            guard matches == iterations else { throw Failure.mismatchedResults(expected: iterations, actual: matches) }
            let elapsed = duration(start, clock.now)
            guard elapsed.isFinite, elapsed >= 0 else { throw Failure.invalidDuration }
            if elapsed == 0 {
                guard attempt + 1 < maxAttempts else { throw Failure.zeroDurationExhausted }
                let (next, overflow) = iterations.multipliedReportingOverflow(by: 2)
                guard !overflow else { throw Failure.invalidConfiguration }
                iterations = next
                continue
            }
            let rate = Double(iterations) / elapsed
            guard rate.isFinite, rate > 0 else { throw Failure.invalidRate }
            return rate
        }
        throw Failure.zeroDurationExhausted
    }
}
