import Foundation

/// Type-safe wrapper for metrics data, replacing [String: Any] dictionaries.
///
/// This provides compile-time safety and better documentation for metrics
/// while maintaining flexibility for different metric types.
public enum MetricValue: Sendable {
    case integer(Int)
    case double(Double)
    case string(String)
    case boolean(Bool)
    case timestamp(Date)
    case duration(TimeInterval)
    
}

/// Type-safe metric keys with predefined common metrics
public enum MetricKey: String, CaseIterable, Sendable {
    // Performance metrics
    case cpuUsage = "cpu_usage"
    case memoryUsage = "memory_usage"
    case diskUsage = "disk_usage"
    case networkLatency = "network_latency"
    
    // Concurrency metrics
    case activeTasks = "active_tasks"
    case threadCount = "thread_count"
    case actorCount = "actor_count"
    case queueDepth = "queue_depth"
    
    // Resource metrics
    case allocatedMemory = "allocated_memory"
    case fileHandles = "file_handles"
    case socketConnections = "socket_connections"
    
    // Timing metrics
    case executionTime = "execution_time"
    case responseTime = "response_time"
    case startupTime = "startup_time"
    
    // Custom metric support
    case custom(String)
    
    public var rawValue: String {
        switch self {
        case .custom(let key): return key
        default: return String(describing: self).replacingOccurrences(of: "custom", with: "")
        }
    }
}

/// Type-safe metrics collection
public struct TypedMetrics: Sendable {
    private var storage: [String: MetricValue] = [:]
    
    public init() {}
    
    /// Set a metric value using predefined key
    public mutating func set(_ key: MetricKey, value: MetricValue) {
        storage[key.rawValue] = value
    }
    
    /// Set a metric value using custom string key
    public mutating func set(_ key: String, value: MetricValue) {
        storage[key] = value
    }
    
    /// Get a metric value
    public func get(_ key: MetricKey) -> MetricValue? {
        storage[key.rawValue]
    }
    
    /// Get a metric value by string key
    public func get(_ key: String) -> MetricValue? {
        storage[key]
    }
    
    
    /// Get typed value helpers
    public func intValue(for key: MetricKey) -> Int? {
        guard case .integer(let value) = get(key) else { return nil }
        return value
    }
    
    public func doubleValue(for key: MetricKey) -> Double? {
        guard case .double(let value) = get(key) else { return nil }
        return value
    }
    
    public func stringValue(for key: MetricKey) -> String? {
        guard case .string(let value) = get(key) else { return nil }
        return value
    }
    
    public func boolValue(for key: MetricKey) -> Bool? {
        guard case .boolean(let value) = get(key) else { return nil }
        return value
    }
    
    public func dateValue(for key: MetricKey) -> Date? {
        guard case .timestamp(let value) = get(key) else { return nil }
        return value
    }
    
    public func durationValue(for key: MetricKey) -> TimeInterval? {
        guard case .duration(let value) = get(key) else { return nil }
        return value
    }
}

