import Foundation

/// A memory profiler for tracking allocations and analyzing memory usage patterns.
///
/// `MemoryProfiler` provides detailed insights into memory behavior during pipeline
/// operations, helping identify memory leaks, excessive allocations, and optimization
/// opportunities.
public actor MemoryProfiler {
    
    // MARK: - Types
    
    /// A snapshot of memory state at a point in time
    public struct MemorySnapshot: Sendable {
        public let timestamp: Date
        public let residentMemory: UInt64
        public let virtualMemory: UInt64
        public let allocations: Int
        public let deallocations: Int
        public let label: String?
        
        public var memoryDelta: Int64 {
            return 0 // Calculated relative to baseline
        }
    }
    
    /// Allocation tracking information
    public struct AllocationInfo: Sendable {
        public let type: String
        public let size: Int
        public let count: Int
        public let totalSize: Int
        
        public var averageSize: Int {
            count > 0 ? totalSize / count : 0
        }
    }
    
    /// Memory usage report
    public struct MemoryReport: Sendable {
        public let startTime: Date
        public let endTime: Date
        public let duration: TimeInterval
        public let snapshots: [MemorySnapshot]
        public let allocations: [AllocationInfo]
        public let peakMemory: UInt64
        public let averageMemory: UInt64
        public let memoryGrowth: Int64
        public let recommendations: [String]
    }
    
    // MARK: - Properties
    
    private var snapshots: [MemorySnapshot] = []
    private var allocationTracking: [String: (count: Int, totalSize: Int)] = [:]
    private var isRecording = false
    private var startTime: Date?
    private var baselineMemory: UInt64 = 0
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Recording Control
    
    /// Starts memory profiling
    public func startRecording() {
        guard !isRecording else { return }
        
        isRecording = true
        startTime = Date()
        snapshots.removeAll()
        allocationTracking.removeAll()
        
        // Capture baseline
        let memory = getCurrentMemoryInfo()
        baselineMemory = memory.resident
        
        snapshots.append(MemorySnapshot(
            timestamp: Date(),
            residentMemory: memory.resident,
            virtualMemory: memory.virtual,
            allocations: 0,
            deallocations: 0,
            label: "Baseline"
        ))
    }
    
    /// Stops recording and generates a report
    public func stopRecording() -> MemoryReport? {
        guard isRecording, let start = startTime else { return nil }
        
        isRecording = false
        let endTime = Date()
        
        // Take final snapshot
        captureSnapshot(label: "Final")
        
        // Calculate statistics
        let peakMemory = snapshots.map { $0.residentMemory }.max() ?? 0
        let averageMemory = snapshots.isEmpty ? 0 : 
            snapshots.map { $0.residentMemory }.reduce(0, +) / UInt64(snapshots.count)
        
        let memoryGrowth = Int64(snapshots.last?.residentMemory ?? 0) - Int64(baselineMemory)
        
        // Generate allocation info
        let allocations = allocationTracking.map { key, value in
            AllocationInfo(
                type: key,
                size: value.count > 0 ? value.totalSize / value.count : 0,
                count: value.count,
                totalSize: value.totalSize
            )
        }.sorted { $0.totalSize > $1.totalSize }
        
        // Generate recommendations
        let recommendations = generateRecommendations(
            peakMemory: peakMemory,
            growth: memoryGrowth,
            allocations: allocations
        )
        
        return MemoryReport(
            startTime: start,
            endTime: endTime,
            duration: endTime.timeIntervalSince(start),
            snapshots: snapshots,
            allocations: allocations,
            peakMemory: peakMemory,
            averageMemory: averageMemory,
            memoryGrowth: memoryGrowth,
            recommendations: recommendations
        )
    }
    
    /// Captures a memory snapshot with optional label
    public func captureSnapshot(label: String? = nil) {
        guard isRecording else { return }
        
        let memory = getCurrentMemoryInfo()
        
        snapshots.append(MemorySnapshot(
            timestamp: Date(),
            residentMemory: memory.resident,
            virtualMemory: memory.virtual,
            allocations: 0, // Would need allocation tracking hooks
            deallocations: 0,
            label: label
        ))
    }
    
    /// Tracks an allocation
    public func trackAllocation(type: String, size: Int) {
        guard isRecording else { return }
        
        let current = allocationTracking[type] ?? (count: 0, totalSize: 0)
        allocationTracking[type] = (
            count: current.count + 1,
            totalSize: current.totalSize + size
        )
    }
    
    // MARK: - Memory Monitoring
    
    /// Monitors memory usage during a block execution
    public func monitor<T: Sendable>(
        label: String,
        sampleInterval: TimeInterval = 0.1,
        _ block: () async throws -> T
    ) async rethrows -> (result: T, report: MemoryReport?) {
        startRecording()
        
        // Start sampling task
        let samplingTask = Task {
            while !Task.isCancelled {
                captureSnapshot()
                try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
            }
        }
        
        defer {
            samplingTask.cancel()
        }
        
        let result = try await block()
        let report = stopRecording()
        
        return (result, report)
    }
    
    // MARK: - Analysis
    
    /// Analyzes memory usage patterns
    public func analyzePatterns(from snapshots: [MemorySnapshot]) -> MemoryPattern {
        guard snapshots.count > 1 else {
            return .stable
        }
        
        // Calculate deltas
        var deltas: [Int64] = []
        for i in 1..<snapshots.count {
            let delta = Int64(snapshots[i].residentMemory) - Int64(snapshots[i-1].residentMemory)
            deltas.append(delta)
        }
        
        // Analyze pattern
        let totalGrowth = Int64(snapshots.last!.residentMemory) - Int64(snapshots.first!.residentMemory)
        let averageDelta = deltas.reduce(0, +) / Int64(deltas.count)
        
        if totalGrowth > Int64(100 * 1024 * 1024) { // > 100MB growth
            return .leak(rate: Double(totalGrowth) / Double(snapshots.count))
        } else if averageDelta > 1024 * 1024 { // > 1MB average growth
            return .growing(rate: Double(averageDelta))
        } else if deltas.allSatisfy({ abs($0) < 1024 * 1024 }) { // < 1MB variance
            return .stable
        } else {
            return .fluctuating
        }
    }
    
    // MARK: - Private Helpers
    
    private func getCurrentMemoryInfo() -> (resident: UInt64, virtual: UInt64) {
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
        
        if kerr == KERN_SUCCESS {
            return (resident: info.resident_size, virtual: info.virtual_size)
        } else {
            return (resident: 0, virtual: 0)
        }
    }
    
    private func generateRecommendations(
        peakMemory: UInt64,
        growth: Int64,
        allocations: [AllocationInfo]
    ) -> [String] {
        var recommendations: [String] = []
        
        // Check for memory leaks
        if growth > 50 * 1024 * 1024 { // > 50MB growth
            recommendations.append("⚠️ Significant memory growth detected (\(formatBytes(growth))). Check for memory leaks.")
        }
        
        // Check peak memory
        if peakMemory > 500 * 1024 * 1024 { // > 500MB peak
            recommendations.append("⚠️ High peak memory usage (\(formatBytes(Int64(peakMemory)))). Consider batching operations.")
        }
        
        // Check for large allocations
        let largeAllocations = allocations.filter { $0.totalSize > 10 * 1024 * 1024 }
        if !largeAllocations.isEmpty {
            recommendations.append("💡 Large allocations detected in: \(largeAllocations.map { $0.type }.joined(separator: ", "))")
            recommendations.append("   Consider using object pooling or streaming processing.")
        }
        
        // Check for frequent small allocations
        let frequentTypes = allocations.filter { $0.count > 1000 && $0.averageSize < 1024 }
        if !frequentTypes.isEmpty {
            recommendations.append("💡 Frequent small allocations in: \(frequentTypes.map { $0.type }.joined(separator: ", "))")
            recommendations.append("   Consider object pooling to reduce allocation overhead.")
        }
        
        if recommendations.isEmpty {
            recommendations.append("✅ Memory usage appears healthy.")
        }
        
        return recommendations
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Supporting Types

/// Memory usage patterns
public enum MemoryPattern: Sendable {
    case stable
    case growing(rate: Double)
    case leak(rate: Double)
    case fluctuating
}

// MARK: - Report Extensions

extension MemoryProfiler.MemoryReport: CustomStringConvertible {
    public var description: String {
        """
        Memory Profile Report
        ====================
        Duration: \(String(format: "%.2f", duration))s
        Peak Memory: \(ByteCountFormatter.string(fromByteCount: Int64(peakMemory), countStyle: .binary))
        Average Memory: \(ByteCountFormatter.string(fromByteCount: Int64(averageMemory), countStyle: .binary))
        Memory Growth: \(ByteCountFormatter.string(fromByteCount: memoryGrowth, countStyle: .binary))
        
        Top Allocations:
        \(allocations.prefix(5).map { "  - \($0.type): \($0.count) allocations, \(ByteCountFormatter.string(fromByteCount: Int64($0.totalSize), countStyle: .binary)) total" }.joined(separator: "\n"))
        
        Recommendations:
        \(recommendations.map { "  \($0)" }.joined(separator: "\n"))
        """
    }
}

// MARK: - Global Profiler

/// Shared memory profiler instance
public let memoryProfiler = MemoryProfiler()