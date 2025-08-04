import Foundation
import PipelineKitCore

/// A specialized pool for PerformanceMeasurement objects to reduce allocations
/// in the performance monitoring hot path.
public actor PerformanceMeasurementPool {
    /// Shared instance for convenience
    public static let shared = PerformanceMeasurementPool()
    
    /// Mutable wrapper for PerformanceMeasurement to allow reset
    /// This is internal to the actor and not exposed directly
    private final class MutableMeasurement {
        var commandName: String = ""
        var executionTime: TimeInterval = 0
        var isSuccess: Bool = true
        var errorMessage: String? = nil
        var metrics: [String: PerformanceMetricValue] = [:]
        
        /// Creates an immutable PerformanceMeasurement from current values
        func toImmutable() -> PerformanceMeasurement {
            PerformanceMeasurement(
                commandName: commandName,
                executionTime: executionTime,
                isSuccess: isSuccess,
                errorMessage: errorMessage,
                metrics: metrics
            )
        }
        
        /// Resets the measurement for reuse
        func reset() {
            commandName = ""
            executionTime = 0
            isSuccess = true
            errorMessage = nil
            metrics.removeAll(keepingCapacity: true)
        }
    }
    
    private let pool: GenericObjectPool<MutableMeasurement>
    
    public init(maxSize: Int = 200) {
        let configuration = GenericObjectPool<MutableMeasurement>.Configuration(
            maxSize: maxSize,
            preAllocateCount: 20,
            trackStatistics: true
        )
        
        self.pool = GenericObjectPool(
            configuration: configuration,
            factory: { MutableMeasurement() },
            reset: { measurement in
                measurement.reset()
            }
        )
    }
    
    /// Pool statistics type alias for public API
    public typealias Statistics = (
        totalCreated: Int,
        currentSize: Int,
        inUse: Int,
        highWaterMark: Int,
        totalBorrows: Int,
        totalReturns: Int
    )
    
    /// Gets pool statistics
    public func getStatistics() async -> Statistics {
        let stats = await pool.getStatistics()
        return (
            totalCreated: stats.totalAllocated,
            currentSize: stats.currentlyAvailable,
            inUse: stats.currentlyInUse,
            highWaterMark: stats.peakUsage,
            totalBorrows: stats.totalBorrows,
            totalReturns: stats.totalReturns
        )
    }
    
    /// Clears the pool
    public func clear() async {
        await pool.clear()
    }
    
    /// Warms up the pool
    public func warmUp(count: Int = 50) async {
        await pool.warmUp(count: count)
    }
    
    /// Creates a performance measurement with the provided values
    public func createMeasurement(
        commandName: String,
        executionTime: TimeInterval,
        isSuccess: Bool,
        errorMessage: String? = nil,
        metrics: [String: PerformanceMetricValue] = [:]
    ) async -> PerformanceMeasurement {
        try! await pool.withBorrowedObject { measurement in
            measurement.commandName = commandName
            measurement.executionTime = executionTime
            measurement.isSuccess = isSuccess
            measurement.errorMessage = errorMessage
            measurement.metrics = metrics
            return measurement.toImmutable()
        }
    }
}

