import XCTest
@testable import PipelineKitTestSupport

final class ThroughputMeasurementTests: XCTestCase {
    func testZeroDurationRetriesWithMoreWork() async throws {
        var durations = [0.0, 2.0]
        var batches: [Int] = []
        let result = try await ThroughputMeasurement.measure(iterations: 3, duration: { _, _ in
            durations.removeFirst()
        }) { iterations in
            batches.append(iterations)
            return iterations
        }
        XCTAssertEqual(batches, [3, 6])
        XCTAssertEqual(result, 3.0, accuracy: 0.0001)
    }

    func testRepeatedZeroDurationFailsAfterBoundedRetries() async {
        var batches: [Int] = []
        do {
            _ = try await ThroughputMeasurement.measure(iterations: 2, maxAttempts: 3, duration: { _, _ in 0 }) { iterations in
                batches.append(iterations)
                return iterations
            }
            XCTFail("Expected exhaustion")
        } catch {
            XCTAssertEqual(error as? ThroughputMeasurement.Failure, .zeroDurationExhausted)
        }
        XCTAssertEqual(batches, [2, 4, 8])
    }

    func testMismatchInZeroDurationBatchFailsBeforeRetry() async {
        var batches: [Int] = []
        var durations = [0.0, 1.0]
        do {
            _ = try await ThroughputMeasurement.measure(iterations: 3, duration: { _, _ in durations.removeFirst() }) { iterations in
                batches.append(iterations)
                return batches.count == 1 ? iterations - 1 : iterations
            }
            XCTFail("Expected mismatch")
        } catch {
            XCTAssertEqual(error as? ThroughputMeasurement.Failure, .mismatchedResults(expected: 3, actual: 2))
        }
        XCTAssertEqual(batches, [3])
    }

    func testInvalidDurationAndRateFail() async {
        for duration in [Double.nan, -.infinity, -1.0] {
            do {
                _ = try await ThroughputMeasurement.measure(iterations: 1, duration: { _, _ in duration }) { $0 }
                XCTFail("Expected invalid duration")
            } catch {
                XCTAssertEqual(error as? ThroughputMeasurement.Failure, .invalidDuration)
            }
        }
        do {
            _ = try await ThroughputMeasurement.measure(iterations: 1, duration: { _, _ in .leastNonzeroMagnitude }) { $0 }
            XCTFail("Expected invalid rate")
        } catch {
            XCTAssertEqual(error as? ThroughputMeasurement.Failure, .invalidRate)
        }
    }

    func testInvalidConfigurationAndRetryOverflowFail() async {
        for (iterations, attempts) in [(0, 1), (1, 0), (Int.max, 2)] {
            do {
                _ = try await ThroughputMeasurement.measure(iterations: iterations, maxAttempts: attempts, duration: { _, _ in 0 }) { $0 }
                XCTFail("Expected invalid configuration")
            } catch {
                XCTAssertEqual(error as? ThroughputMeasurement.Failure, .invalidConfiguration)
            }
        }
    }

}
