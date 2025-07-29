import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
import Darwin.malloc
#endif

/// Statistics from malloc_zone_statistics.
public struct AllocationStatistics: Sendable {
    public let blocksInUse: Int
    public let sizeInUse: Int
    public let maxSizeInUse: Int
    public let sizeAllocated: Int
}

/// Utilities for tracking memory usage during benchmarks.
public enum MemoryTracking {
    
    /// Get current memory usage of the process in bytes.
    public static func currentMemoryUsage() -> Int {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        #else
        // Linux or other platforms - return 0 for now
        return 0
        #endif
    }
    
    /// Get detailed allocation statistics using malloc_statistics.
    public static func getAllocationStatistics() -> AllocationStatistics {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        
        return AllocationStatistics(
            blocksInUse: Int(stats.blocks_in_use),
            sizeInUse: Int(stats.size_in_use),
            maxSizeInUse: Int(stats.max_size_in_use),
            sizeAllocated: Int(stats.size_allocated)
        )
        #else
        return AllocationStatistics(
            blocksInUse: 0,
            sizeInUse: 0,
            maxSizeInUse: 0,
            sizeAllocated: 0
        )
        #endif
    }
    
    /// Track memory allocations during a block of code.
    public static func trackAllocations<T>(
        during block: () async throws -> T
    ) async throws -> (result: T, allocations: Int, peakMemory: Int) {
        let startStats = getAllocationStatistics()
        let startMemory = currentMemoryUsage()
        var peakMemory = startMemory
        
        let result = try await block()
        
        let endStats = getAllocationStatistics()
        let endMemory = currentMemoryUsage()
        peakMemory = max(peakMemory, endMemory)
        
        let allocations = endStats.blocksInUse - startStats.blocksInUse
        
        return (result, allocations, peakMemory)
    }
    
    /// Memory pressure levels for testing.
    public enum PressureLevel {
        case low
        case medium
        case high
        
        var allocationSize: Int {
            switch self {
            case .low: return 1_000_000      // 1 MB
            case .medium: return 10_000_000   // 10 MB
            case .high: return 100_000_000    // 100 MB
            }
        }
    }
    
    /// Apply memory pressure during benchmarks.
    public static func applyMemoryPressure(
        level: PressureLevel,
        duration: TimeInterval
    ) async {
        let size = level.allocationSize
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        
        // Touch memory to ensure it's allocated
        memset(buffer, 0, size)
        
        // Hold for duration
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

/// Helper to track pool statistics during benchmarks.
@MainActor
public struct PoolStatisticsTracker {
    private var initialStats: [String: Any] = [:]
    
    public init() {}
    
    /// Record initial pool statistics.
    public mutating func recordInitialStats() {
        // Access PipelineKit pool statistics if available
        // This would integrate with CommandContextPool, etc.
    }
    
    /// Get pool efficiency metrics.
    public func getPoolEfficiency() -> (hitRate: Double, allocations: Int) {
        // Calculate based on pool statistics
        // Placeholder for now
        return (hitRate: 0.0, allocations: 0)
    }
}

/// High-resolution timer for precise measurements.
public struct HighResolutionTimer {
    private let start: UInt64
    
    public init() {
        self.start = Self.mach_absolute_time()
    }
    
    public var elapsed: TimeInterval {
        let end = Self.mach_absolute_time()
        let elapsed = end - start
        
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        
        let nanos = elapsed * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private static func mach_absolute_time() -> UInt64 {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        return Darwin.mach_absolute_time()
        #else
        return UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        #endif
    }
}

/// Memory snapshot for detailed analysis.
public struct MemorySnapshot: Sendable {
    public let timestamp: Date
    public let residentMemory: Int
    public let virtualMemory: Int
    public let allocatedObjects: Int
    
    public static func current() -> MemorySnapshot {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        
        if result == KERN_SUCCESS {
            return MemorySnapshot(
                timestamp: Date(),
                residentMemory: Int(info.resident_size),
                virtualMemory: Int(info.virtual_size),
                allocatedObjects: 0 // Would need malloc zone introspection
            )
        }
        #endif
        
        return MemorySnapshot(
            timestamp: Date(),
            residentMemory: 0,
            virtualMemory: 0,
            allocatedObjects: 0
        )
    }
}