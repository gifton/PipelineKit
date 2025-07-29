import Foundation

/// Runs benchmarks and collects measurements.
public actor BenchmarkRunner {
    private let configuration: BenchmarkConfiguration
    private var results: [BenchmarkResult] = []
    
    public init(configuration: BenchmarkConfiguration = .default) {
        self.configuration = configuration
    }
    
    /// Run a single benchmark.
    public func run<B: Benchmark>(_ benchmark: B) async throws -> BenchmarkResult {
        if !configuration.quiet {
            print("Running benchmark: \(benchmark.name)")
            print("Iterations: \(benchmark.iterations) (warmup: \(benchmark.warmupIterations))")
        }
        
        // Setup
        try await benchmark.setUp()
        
        // Store teardown task to ensure it completes
        let teardownTask = Task {
            try? await benchmark.tearDown()
        }
        
        // Warm-up phase
        if !configuration.quiet {
            print("Warming up...")
        }
        
        for i in 0..<benchmark.warmupIterations {
            try await benchmark.run()
            
            if let interval = configuration.progressInterval,
               i > 0 && i % interval == 0 && !configuration.quiet {
                print("  Warmup: \(i)/\(benchmark.warmupIterations)")
            }
        }
        
        // Measurement phase
        if !configuration.quiet {
            print("Measuring...")
        }
        
        var measurements: [BenchmarkMeasurement] = []
        let startTime = Date()
        
        for i in 0..<benchmark.iterations {
            // Check timeout
            if Date().timeIntervalSince(startTime) > configuration.timeout {
                throw BenchmarkError.timeout(
                    elapsed: Date().timeIntervalSince(startTime),
                    completed: i
                )
            }
            
            let measurement = try await measureIteration(benchmark)
            measurements.append(measurement)
            
            if let interval = configuration.progressInterval,
               i > 0 && i % interval == 0 && !configuration.quiet {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(i) / elapsed
                print("  Progress: \(i)/\(benchmark.iterations) (%.0f iter/s)", rate)
            }
        }
        
        // Remove outliers for stable statistics
        let cleanMeasurements = Statistics.removeOutliers(from: measurements)
        let outlierCount = measurements.count - cleanMeasurements.count
        
        // Calculate statistics
        let statistics = Statistics.calculate(from: cleanMeasurements)
        let memoryStats = configuration.measureMemory
            ? Statistics.calculateMemory(from: cleanMeasurements)
            : nil
        
        // Build warnings
        var warnings: [String] = []
        if outlierCount > 0 {
            warnings.append("Removed \(outlierCount) outliers")
        }
        if !statistics.isStable {
            warnings.append("High variance detected (CV: \(String(format: "%.1f%%", statistics.coefficientOfVariation * 100)))")
        }
        
        let result = BenchmarkResult(
            name: benchmark.name,
            measurements: measurements,
            statistics: statistics,
            memoryStatistics: memoryStats,
            metadata: BenchmarkMetadata(),
            warnings: warnings
        )
        
        // Store result
        results.append(result)
        
        if !configuration.quiet {
            printSummary(result)
        }
        
        // Ensure teardown completes before returning
        await teardownTask.value
        
        return result
    }
    
    /// Run multiple benchmarks.
    public func runAll(_ benchmarks: [any Benchmark]) async throws -> [BenchmarkResult] {
        var allResults: [BenchmarkResult] = []
        
        for benchmark in benchmarks {
            let result = try await run(benchmark)
            allResults.append(result)
            
            if !configuration.quiet && benchmarks.count > 1 {
                print("") // Spacing between benchmarks
            }
        }
        
        return allResults
    }
    
    /// Get all collected results.
    public func getResults() -> [BenchmarkResult] {
        results
    }
    
    /// Clear all results.
    public func clearResults() {
        results.removeAll()
    }
    
    // MARK: - Private
    
    private func measureIteration<B: Benchmark>(_ benchmark: B) async throws -> BenchmarkMeasurement {
        if configuration.measureMemory {
            // Use detailed allocation tracking
            let timer = HighResolutionTimer()
            let (_, allocations, peakMemory) = try await MemoryTracking.trackAllocations {
                try await benchmark.run()
            }
            let duration = timer.elapsed
            
            let currentMemory = MemoryTracking.currentMemoryUsage()
            
            return BenchmarkMeasurement(
                duration: duration,
                memoryUsed: currentMemory,
                allocations: allocations,
                peakMemory: peakMemory
            )
        } else {
            // Just measure time
            let timer = HighResolutionTimer()
            try await benchmark.run()
            let duration = timer.elapsed
            
            return BenchmarkMeasurement(
                duration: duration,
                memoryUsed: nil,
                allocations: nil,
                peakMemory: nil
            )
        }
    }
    
    private func printSummary(_ result: BenchmarkResult) {
        print("\nResults for '\(result.name)':")
        print("  Samples:     \(result.statistics.count)")
        print("  Mean:        \(formatDuration(result.statistics.mean))")
        print("  Median:      \(formatDuration(result.statistics.median))")
        print("  Std Dev:     \(formatDuration(result.statistics.standardDeviation))")
        print("  Min:         \(formatDuration(result.statistics.min))")
        print("  Max:         \(formatDuration(result.statistics.max))")
        
        if let p95 = result.statistics.p95 {
            print("  P95:         \(formatDuration(p95))")
        }
        if let p99 = result.statistics.p99 {
            print("  P99:         \(formatDuration(p99))")
        }
        
        if let memory = result.memoryStatistics {
            print("\nMemory:")
            print("  Average:     \(formatBytes(Int(memory.averageMemory)))")
            print("  Peak:        \(formatBytes(memory.peakMemory))")
        }
        
        if !result.warnings.isEmpty {
            print("\nWarnings:")
            for warning in result.warnings {
                print("  - \(warning)")
            }
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.000001 {
            return String(format: "%.0f ns", seconds * 1_000_000_000)
        } else if seconds < 0.001 {
            return String(format: "%.2f µs", seconds * 1_000_000)
        } else if seconds < 1.0 {
            return String(format: "%.2f ms", seconds * 1_000)
        } else {
            return String(format: "%.2f s", seconds)
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

/// Errors that can occur during benchmark execution.
public enum BenchmarkError: LocalizedError {
    case timeout(elapsed: TimeInterval, completed: Int)
    case setupFailed(Error)
    case executionFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .timeout(let elapsed, let completed):
            return "Benchmark timed out after \(elapsed)s (\(completed) iterations completed)"
        case .setupFailed(let error):
            return "Benchmark setup failed: \(error)"
        case .executionFailed(let error):
            return "Benchmark execution failed: \(error)"
        }
    }
}