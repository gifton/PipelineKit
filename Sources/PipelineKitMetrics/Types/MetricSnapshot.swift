import Foundation

/// A lightweight snapshot of a metric at a point in time.
///
/// This type represents the minimal data needed to export a metric,
/// using primitive types for efficiency and avoiding complex dependencies.
public struct MetricSnapshot: Sendable, Codable, Hashable {
    /// The metric name (e.g., "api.requests.count")
    public let name: String
    
    /// The type of metric (counter, gauge, histogram, timer)
    public let type: String
    
    /// The metric value (optional for increment-only operations)
    public let value: Double?
    
    /// Unix timestamp in milliseconds
    public let timestamp: UInt64
    
    /// Dimensional tags for filtering and grouping
    public let tags: [String: String]
    
    /// Optional unit of measurement
    public let unit: String?
    
    /// Creates a new metric snapshot.
    public init(
        name: String,
        type: String,
        value: Double? = nil,
        timestamp: UInt64? = nil,
        tags: [String: String] = [:],
        unit: String? = nil
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.timestamp = timestamp ?? UInt64(Date().timeIntervalSince1970 * 1000)
        self.tags = tags
        self.unit = unit
    }
}

// MARK: - Convenience Initializers

public extension MetricSnapshot {
    /// Creates a counter snapshot.
    static func counter(
        _ name: String,
        value: Double = 1.0,
        tags: [String: String] = [:]
    ) -> MetricSnapshot {
        MetricSnapshot(
            name: name,
            type: "counter",
            value: value,
            tags: tags
        )
    }
    
    /// Creates a gauge snapshot.
    static func gauge(
        _ name: String,
        value: Double,
        tags: [String: String] = [:],
        unit: String? = nil
    ) -> MetricSnapshot {
        MetricSnapshot(
            name: name,
            type: "gauge",
            value: value,
            tags: tags,
            unit: unit
        )
    }
    
    /// Creates a timer snapshot.
    static func timer(
        _ name: String,
        duration: TimeInterval,
        tags: [String: String] = [:]
    ) -> MetricSnapshot {
        MetricSnapshot(
            name: name,
            type: "timer",
            value: duration * 1000, // Convert to milliseconds
            tags: tags,
            unit: "ms"
        )
    }
}