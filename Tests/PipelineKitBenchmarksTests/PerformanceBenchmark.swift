import XCTest
@testable import PipelineKit

/// Base class for performance benchmarks with built-in measurement infrastructure
class PerformanceBenchmark: XCTestCase {
    /// Default number of iterations for benchmarks
    private static let defaultIterations = 100
    
    /// Measures the performance of a block of code
    /// - Parameters:
    ///   - name: Name of the benchmark
    ///   - iterations: Number of iterations (default: 100)
    ///   - block: The code to benchmark
    private func benchmark(
        _ name: String,
        iterations: Int = defaultIterations,
        block: @escaping () async throws -> Void
    ) async throws {
        measure(metrics: [
            XCTClockMetric(),
            XCTMemoryMetric(),
            XCTCPUMetric()
        ]) {
            let semaphore = DispatchSemaphore(value: 0)
            
            Task {
                for _ in 0..<iterations {
                    try? await block()
                }
                semaphore.signal()
            }
            
            semaphore.wait()
        }
    }
    
    /// Measures throughput (operations per second)
    /// - Parameters:
    ///   - name: Name of the benchmark
    ///   - duration: How long to run the test
    ///   - block: The code to benchmark
    /// - Returns: Operations per second
    private @discardableResult
    func benchmarkThroughput(
        _ name: String,
        duration: TimeInterval = 1.0,
        block: @escaping () async throws -> Void
    ) async throws -> Double {
        let startTime = Date()
        var operations = 0
        
        while Date().timeIntervalSince(startTime) < duration {
            try await block()
            operations += 1
        }
        
        let actualDuration = Date().timeIntervalSince(startTime)
        let opsPerSecond = Double(operations) / actualDuration
        
        print("[\(name)] Throughput: \(Int(opsPerSecond)) ops/sec")
        return opsPerSecond
    }
    
    /// Measures latency percentiles
    /// - Parameters:
    ///   - name: Name of the benchmark
    ///   - samples: Number of samples to collect
    ///   - block: The code to benchmark
    /// - Returns: Latency statistics
    private @discardableResult
    func benchmarkLatency(
        _ name: String,
        samples: Int = 1000,
        block: @escaping () async throws -> Void
    ) async throws -> LatencyStats {
        var latencies: [TimeInterval] = []
        latencies.reserveCapacity(samples)
        
        for _ in 0..<samples {
            let start = Date()
            try await block()
            let latency = Date().timeIntervalSince(start)
            latencies.append(latency)
        }
        
        latencies.sort()
        
        let stats = LatencyStats(
            min: latencies.first ?? 0,
            max: latencies.last ?? 0,
            mean: latencies.reduce(0, +) / Double(latencies.count),
            p50: percentile(latencies, 0.50),
            p90: percentile(latencies, 0.90),
            p95: percentile(latencies, 0.95),
            p99: percentile(latencies, 0.99)
        )
        
        print("[\(name)] Latency - p50: \(formatTime(stats.p50)), p90: \(formatTime(stats.p90)), p99: \(formatTime(stats.p99))")
        return stats
    }
    
    /// Compares performance of two implementations
    /// - Parameters:
    ///   - name: Name of the comparison
    ///   - baseline: Baseline implementation
    ///   - optimized: Optimized implementation
    private func comparePerformance(
        _ name: String,
        baseline: @escaping () async throws -> Void,
        optimized: @escaping () async throws -> Void
    ) async throws {
        print("\n=== Performance Comparison: \(name) ===")
        
        // Measure baseline
        let baselineStart = Date()
        for _ in 0..<Self.defaultIterations {
            try await baseline()
        }
        let baselineTime = Date().timeIntervalSince(baselineStart)
        
        // Measure optimized
        let optimizedStart = Date()
        for _ in 0..<Self.defaultIterations {
            try await optimized()
        }
        let optimizedTime = Date().timeIntervalSince(optimizedStart)
        
        // Calculate improvement
        let improvement = ((baselineTime - optimizedTime) / baselineTime) * 100
        let speedup = baselineTime / optimizedTime
        
        print("Baseline:  \(formatTime(baselineTime))")
        print("Optimized: \(formatTime(optimizedTime))")
        print("Speedup:   \(String(format: "%.2fx", speedup))")
        print("Improvement: \(String(format: "%.1f%%", improvement))")
        
        XCTAssertLessThan(optimizedTime, baselineTime, "Optimized should be faster than baseline")
    }
    
    // MARK: - Helpers
    
    private func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        if time < 0.001 {
            return String(format: "%.0f µs", time * 1_000_000)
        } else if time < 1.0 {
            return String(format: "%.1f ms", time * 1000)
        } else {
            return String(format: "%.2f s", time)
        }
    }
}

/// Latency statistics
struct LatencyStats {
    let min: TimeInterval
    let max: TimeInterval
    let mean: TimeInterval
    let p50: TimeInterval
    let p90: TimeInterval
    let p95: TimeInterval
    let p99: TimeInterval
}
