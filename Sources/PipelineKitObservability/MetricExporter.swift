import Foundation
import PipelineKitCore

/// Protocol for exporting metrics to various destinations and formats.
///
/// MetricExporter defines the contract for all export implementations.
/// Exporters should be thread-safe (typically implemented as actors) and
/// handle their own buffering, error handling, and resource management.
///
/// ## Implementation Guidelines
/// - Use actors for thread safety
/// - Implement proper error handling
/// - Support both streaming and batch modes
/// - Clean up resources in shutdown()
///
/// ## Example Implementation
/// ```swift
/// actor JSONExporter: MetricExporter {
///     func export(_ metric: MetricDataPoint) async throws {
///         // Export single metric
///     }
///     
///     func exportBatch(_ metrics: [MetricDataPoint]) async throws {
///         // Export multiple metrics efficiently
///     }
/// }
/// ```
public protocol MetricExporter: Sendable {
    /// Exports a single metric data point.
    ///
    /// This method is called for real-time streaming export.
    /// Implementations should handle buffering if needed.
    ///
    /// - Parameter metric: The metric to export.
    /// - Throws: ExportError if the export fails.
    func export(_ metric: MetricDataPoint) async throws
    
    /// Exports a batch of metric data points.
    ///
    /// This method enables efficient bulk export operations.
    /// Implementations should optimize for batch processing.
    ///
    /// - Parameter metrics: Array of metrics to export.
    /// - Throws: ExportError if the export fails.
    func exportBatch(_ metrics: [MetricDataPoint]) async throws
    
    /// Exports aggregated metrics.
    ///
    /// This method handles pre-aggregated metrics from time windows.
    /// Implementations may format these differently than raw metrics.
    ///
    /// - Parameter metrics: Array of aggregated metrics to export.
    /// - Throws: ExportError if the export fails.
    func exportAggregated(_ metrics: [AggregatedMetrics]) async throws
    
    /// Flushes any buffered metrics.
    ///
    /// Forces immediate export of any buffered data.
    /// Should be called periodically and before shutdown.
    ///
    /// - Throws: ExportError if the flush fails.
    func flush() async throws
    
    /// Shuts down the exporter gracefully.
    ///
    /// Flushes remaining data and releases resources.
    /// After shutdown, the exporter should not accept new metrics.
    func shutdown() async
    
    /// Returns the current status of the exporter.
    var status: ExporterStatus { get async }
}

// MARK: - Supporting Types

/// Status of an exporter.
public struct ExporterStatus: Sendable {
    /// Whether the exporter is currently active.
    public let isActive: Bool
    
    /// Number of metrics in the export queue.
    public let queueDepth: Int
    
    /// Number of successful exports.
    public let successCount: Int
    
    /// Number of failed exports.
    public let failureCount: Int
    
    /// Last export timestamp.
    public let lastExportTime: Date?
    
    /// Last error if any.
    public let lastError: String?
    
    public init(
        isActive: Bool = true,
        queueDepth: Int = 0,
        successCount: Int = 0,
        failureCount: Int = 0,
        lastExportTime: Date? = nil,
        lastError: String? = nil
    ) {
        self.isActive = isActive
        self.queueDepth = queueDepth
        self.successCount = successCount
        self.failureCount = failureCount
        self.lastExportTime = lastExportTime
        self.lastError = lastError
    }
}


// MARK: - Configuration

/// Base configuration for exporters.
public protocol ExportConfiguration: Sendable {
    /// Maximum number of metrics to buffer.
    var bufferSize: Int { get }
    
    /// Interval between automatic flushes.
    var flushInterval: TimeInterval { get }
    
    /// Whether to export in real-time or batch mode.
    var realTimeExport: Bool { get }
}

/// Default configuration values.
public struct DefaultExportConfiguration: ExportConfiguration {
    public let bufferSize: Int
    public let flushInterval: TimeInterval
    public let realTimeExport: Bool
    
    public init(
        bufferSize: Int = 1000,
        flushInterval: TimeInterval = 10.0,
        realTimeExport: Bool = false
    ) {
        self.bufferSize = bufferSize
        self.flushInterval = flushInterval
        self.realTimeExport = realTimeExport
    }
}

// MARK: - Extensions

/// Default implementations for optional methods.
public extension MetricExporter {
    /// Default implementation exports metrics one by one.
    func exportBatch(_ metrics: [MetricDataPoint]) async throws {
        for metric in metrics {
            try await export(metric)
        }
    }
    
    /// Default implementation converts aggregated metrics to data points.
    func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
        // Default implementation exports aggregated metrics as individual points
        var dataPoints: [MetricDataPoint] = []
        
        for aggregated in metrics {
            // Create a summary data point for each aggregated metric
            let tags = aggregated.tags.merging([
                "window": "\(Int(aggregated.window.duration))s",
                "aggregation": "true"
            ]) { _, new in new }
            
            // Export key statistics as separate metrics
            switch aggregated.statistics {
            case .basic(let stats):
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).mean",
                    type: .gauge,
                    value: stats.mean,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).min",
                    type: .gauge,
                    value: stats.min,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).max",
                    type: .gauge,
                    value: stats.max,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                
            case .counter(let stats):
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).rate",
                    type: .gauge,
                    value: stats.rate,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).increase",
                    type: .counter,
                    value: stats.increase,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                
            case .histogram(let stats):
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).p50",
                    type: .gauge,
                    value: stats.p50,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).p95",
                    type: .gauge,
                    value: stats.p95,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
                dataPoints.append(MetricDataPoint(
                    name: "\(aggregated.name).p99",
                    type: .gauge,
                    value: stats.p99,
                    timestamp: aggregated.timestamp,
                    tags: tags
                ))
            }
        }
        
        try await exportBatch(dataPoints)
    }
}
