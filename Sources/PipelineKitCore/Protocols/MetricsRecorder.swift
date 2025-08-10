import Foundation

/// Protocol for recording metrics in a type-safe manner.
///
/// This protocol provides the minimal interface that other modules
/// need to record metrics without depending on the full metrics implementation.
public protocol MetricsRecorder: Sendable {
    /// Record a metric snapshot.
    ///
    /// - Parameter snapshot: The metric snapshot to record
    func record(_ snapshot: MetricSnapshot) async

    /// Flush any pending metrics.
    func flush() async
}

/// Protocol for providing metrics data.
public protocol MetricsProvider: Sendable {
    /// Get all current metrics.
    ///
    /// - Returns: Array of metric snapshots
    func metrics() async -> [MetricSnapshot]

    /// Get a stream of metrics.
    ///
    /// - Returns: Async stream of metric snapshots
    func metricsStream() -> AsyncStream<MetricSnapshot>
}

/// A type-erased metric snapshot for cross-module use.
///
/// This is defined in Core to allow other modules to work with metrics
/// without depending on the full PipelineKitMetrics module.
public struct MetricSnapshot: Sendable, Codable {
    public let name: String
    public let type: String
    public let value: Double
    public let timestamp: Date
    public let tags: [String: String]
    public let unit: String?

    public init(
        name: String,
        type: String,
        value: Double,
        timestamp: Date = Date(),
        tags: [String: String] = [:],
        unit: String? = nil
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.timestamp = timestamp
        self.tags = tags
        self.unit = unit
    }
}
