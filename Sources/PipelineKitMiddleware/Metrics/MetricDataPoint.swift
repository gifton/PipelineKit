import Foundation

/// A single metric data point captured during stress testing.
///
/// MetricDataPoint is designed to be compact and efficient for high-frequency
/// collection. It includes essential information while minimizing memory overhead.
public struct MetricDataPoint: Sendable, Codable {
    /// Timestamp when the metric was recorded.
    public let timestamp: Date
    
    /// Name of the metric (e.g., "cpu.usage", "memory.allocated").
    public let name: String
    
    /// The metric value.
    public let value: Double
    
    /// Type of metric for proper aggregation.
    public let type: MetricType
    
    /// Optional tags for filtering and grouping.
    /// Keep minimal for performance (e.g., ["simulator": "memory", "phase": "ramp"])
    public let tags: [String: String]
    
    public init(
        timestamp: Date = Date(),
        name: String,
        value: Double,
        type: MetricType,
        tags: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.name = name
        self.value = value
        self.type = type
        self.tags = tags
    }
    
    /// Estimated memory size in bytes (for capacity planning).
    public static var estimatedSize: Int {
        // Date (8) + String (~32) + Double (8) + Type (1) + Tags (~64) = ~113 bytes
        // Round up to 128 for safety
        return 128
    }
}

// MARK: - Convenience Extensions

extension MetricDataPoint {
    /// Creates a gauge metric sample.
    public static func gauge(
        _ name: String,
        value: Double,
        tags: [String: String] = [:]
    ) -> MetricDataPoint {
        MetricDataPoint(
            name: name,
            value: value,
            type: .gauge,
            tags: tags
        )
    }
    
    /// Creates a counter metric sample.
    public static func counter(
        _ name: String,
        value: Double,
        tags: [String: String] = [:]
    ) -> MetricDataPoint {
        MetricDataPoint(
            name: name,
            value: value,
            type: .counter,
            tags: tags
        )
    }
    
    /// Creates a histogram metric sample.
    public static func histogram(
        _ name: String,
        value: Double,
        tags: [String: String] = [:]
    ) -> MetricDataPoint {
        MetricDataPoint(
            name: name,
            value: value,
            type: .histogram,
            tags: tags
        )
    }
    
    /// Creates a timer metric sample (value in seconds).
    public static func timer(
        _ name: String,
        seconds: Double,
        tags: [String: String] = [:]
    ) -> MetricDataPoint {
        MetricDataPoint(
            name: name,
            value: seconds,
            type: .timer,
            tags: tags
        )
    }
}

// MARK: - Metric Identifiers

/// Common metric names used throughout the stress testing framework.
public enum MetricName {
    // System metrics
    public static let cpuUsage = "system.cpu.usage"
    public static let memoryUsage = "system.memory.usage"
    public static let threadCount = "system.threads.count"
    public static let processMemory = "system.process.memory"
    
    // Memory simulator metrics
    public static let memoryAllocated = "memory.allocated.bytes"
    public static let memoryAllocationRate = "memory.allocation.rate"
    public static let memoryBufferCount = "memory.buffers.count"
    
    // CPU simulator metrics
    public static let cpuTargetUsage = "cpu.target.usage"
    public static let cpuActualUsage = "cpu.actual.usage"
    public static let cpuLoadThreads = "cpu.load.threads"
    
    // Test execution metrics
    public static let testDuration = "test.duration.seconds"
    public static let testErrors = "test.errors.count"
}

/// Common tags used for metric grouping.
public enum MetricTag {
    public static let simulator = "simulator"
    public static let scenario = "scenario"
    public static let phase = "phase"
    public static let core = "core"
}