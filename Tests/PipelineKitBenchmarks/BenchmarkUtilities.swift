import XCTest
import PipelineKit
import Foundation

/// Utilities for performance benchmarking
struct BenchmarkUtilities {
    
    /// Measures memory usage before and after a block execution
    static func measureMemory<T>(
        iterations: Int = 10,
        _ block: () async throws -> T
    ) async rethrows -> MemoryMetrics {
        var initialMemory: UInt64 = 0
        var peakMemory: UInt64 = 0
        var finalMemory: UInt64 = 0
        var allocationCount = 0
        
        for _ in 0..<iterations {
            initialMemory = getCurrentMemoryUsage()
            _ = try await block()
            finalMemory = getCurrentMemoryUsage()
            peakMemory = max(peakMemory, finalMemory)
            if finalMemory > initialMemory {
                allocationCount += 1
            }
        }
        
        return MemoryMetrics(
            initial: initialMemory,
            peak: peakMemory,
            final: finalMemory,
            allocations: allocationCount,
            iterations: iterations
        )
    }
    
    /// Gets current memory usage in bytes
    static func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
    
    /// Warms up the system before benchmarking
    static func warmup(iterations: Int = 5, _ block: () async throws -> Void) async rethrows {
        for _ in 0..<iterations {
            try await block()
        }
    }
    
    /// Measures throughput in operations per second
    static func measureThroughput(
        operations: Int,
        timeout: TimeInterval = 10,
        _ block: () async throws -> Void
    ) async rethrows -> ThroughputMetrics {
        let startTime = Date()
        var completedOperations = 0
        let deadline = startTime.addingTimeInterval(timeout)
        
        while Date() < deadline && completedOperations < operations {
            try await block()
            completedOperations += 1
        }
        
        let duration = Date().timeIntervalSince(startTime)
        let throughput = Double(completedOperations) / duration
        
        return ThroughputMetrics(
            operations: completedOperations,
            duration: duration,
            throughputPerSecond: throughput
        )
    }
    
    /// Creates a statistical summary from multiple measurements
    static func summarize(_ measurements: [TimeInterval]) -> StatisticalSummary {
        guard !measurements.isEmpty else {
            return StatisticalSummary(
                mean: 0, median: 0, min: 0, max: 0,
                standardDeviation: 0, percentile95: 0
            )
        }
        
        let sorted = measurements.sorted()
        let mean = measurements.reduce(0, +) / Double(measurements.count)
        let median = sorted[sorted.count / 2]
        let min = sorted.first ?? 0
        let max = sorted.last ?? 0
        
        // Calculate standard deviation
        let variance = measurements.reduce(0) { sum, value in
            sum + pow(value - mean, 2)
        } / Double(measurements.count)
        let standardDeviation = sqrt(variance)
        
        // Calculate 95th percentile
        let index95 = Int(Double(sorted.count) * 0.95)
        let percentile95 = sorted[min(index95, sorted.count - 1)]
        
        return StatisticalSummary(
            mean: mean,
            median: median,
            min: min,
            max: max,
            standardDeviation: standardDeviation,
            percentile95: percentile95
        )
    }
}

/// Memory usage metrics
struct MemoryMetrics: CustomStringConvertible {
    let initial: UInt64
    let peak: UInt64
    let final: UInt64
    let allocations: Int
    let iterations: Int
    
    var averageAllocation: UInt64 {
        guard allocations > 0 else { return 0 }
        return (final - initial) / UInt64(allocations)
    }
    
    var description: String {
        """
        Memory Metrics:
          Initial: \(formatBytes(initial))
          Peak: \(formatBytes(peak))
          Final: \(formatBytes(final))
          Allocations: \(allocations)/\(iterations) iterations
          Average per allocation: \(formatBytes(averageAllocation))
        """
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Throughput performance metrics
struct ThroughputMetrics: CustomStringConvertible {
    let operations: Int
    let duration: TimeInterval
    let throughputPerSecond: Double
    
    var description: String {
        """
        Throughput Metrics:
          Operations: \(operations)
          Duration: \(String(format: "%.3f", duration))s
          Throughput: \(String(format: "%.0f", throughputPerSecond)) ops/sec
        """
    }
}

/// Statistical summary of measurements
struct StatisticalSummary: CustomStringConvertible {
    let mean: TimeInterval
    let median: TimeInterval
    let min: TimeInterval
    let max: TimeInterval
    let standardDeviation: TimeInterval
    let percentile95: TimeInterval
    
    var description: String {
        """
        Statistical Summary:
          Mean: \(formatTime(mean))
          Median: \(formatTime(median))
          Min: \(formatTime(min))
          Max: \(formatTime(max))
          Std Dev: \(formatTime(standardDeviation))
          95th %ile: \(formatTime(percentile95))
        """
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        if time < 0.001 {
            return String(format: "%.3f µs", time * 1_000_000)
        } else if time < 1.0 {
            return String(format: "%.3f ms", time * 1000)
        } else {
            return String(format: "%.3f s", time)
        }
    }
}

// MARK: - Test Command Types

/// Simple test command for benchmarking
struct BenchmarkCommand: Command {
    typealias Result = String
    let id: UUID = UUID()
    let payload: String
    
    func execute() async throws -> String {
        // Simulate some work
        try await Task.sleep(nanoseconds: 100)
        return "Processed: \(payload)"
    }
}

/// Memory-intensive command for testing allocations
struct MemoryIntensiveCommand: Command {
    typealias Result = Data
    let size: Int
    
    func execute() async throws -> Data {
        // Allocate data to test memory behavior
        var data = Data(count: size)
        for i in 0..<size {
            data[i] = UInt8(i % 256)
        }
        return data
    }
}

/// CPU-intensive command for testing computation
struct CPUIntensiveCommand: Command {
    typealias Result = Double
    let iterations: Int
    
    func execute() async throws -> Double {
        var result: Double = 0
        for i in 0..<iterations {
            result += sin(Double(i)) * cos(Double(i))
        }
        return result
    }
}

// MARK: - Test Handlers

/// Simple handler for benchmark command
actor BenchmarkHandler: CommandHandler {
    typealias CommandType = BenchmarkCommand
    
    func handle(_ command: BenchmarkCommand) async throws -> String {
        try await command.execute()
    }
}

/// Handler for memory-intensive command
actor MemoryIntensiveHandler: CommandHandler {
    typealias CommandType = MemoryIntensiveCommand
    
    func handle(_ command: MemoryIntensiveCommand) async throws -> Data {
        try await command.execute()
    }
}

/// Handler for CPU-intensive command  
actor CPUIntensiveHandler: CommandHandler {
    typealias CommandType = CPUIntensiveCommand
    
    func handle(_ command: CPUIntensiveCommand) async throws -> Double {
        try await command.execute()
    }
}

// MARK: - Benchmark Configuration

struct BenchmarkConfiguration {
    let warmupIterations: Int
    let measurementIterations: Int
    let operationCount: Int
    let concurrencyLevel: Int
    let timeout: TimeInterval
    
    static let `default` = BenchmarkConfiguration(
        warmupIterations: 5,
        measurementIterations: 100,
        operationCount: 10000,
        concurrencyLevel: 10,
        timeout: 30
    )
    
    static let stress = BenchmarkConfiguration(
        warmupIterations: 10,
        measurementIterations: 1000,
        operationCount: 100000,
        concurrencyLevel: 100,
        timeout: 60
    )
    
    static let quick = BenchmarkConfiguration(
        warmupIterations: 2,
        measurementIterations: 10,
        operationCount: 100,
        concurrencyLevel: 5,
        timeout: 10
    )
}