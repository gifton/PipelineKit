import PipelineKitCore
import Foundation

/// Configuration for metrics collection behavior.
///
/// This configuration allows customization of how metrics are stored,
/// aggregated, and prepared for export.
public struct MetricsConfiguration: Sendable {
    // MARK: - Storage Configuration
    
    /// Maximum number of metric data points to store.
    public let maxDataPoints: Int
    
    /// Maximum number of unique metric names to track.
    public let maxMetricNames: Int
    
    /// Maximum number of unique tag combinations per metric.
    public let maxTagCombinations: Int
    
    /// How long to retain metrics before automatic expiry.
    public let retentionPeriod: TimeInterval
    
    // MARK: - Aggregation Configuration
    
    /// Time windows for metric aggregation.
    public let aggregationWindows: [TimeInterval]
    
    /// Whether to compute percentiles for histograms.
    public let computePercentiles: Bool
    
    /// Percentiles to compute for histogram metrics.
    public let percentiles: [Double]
    
    // MARK: - Behavior Configuration
    
    /// Whether to automatically aggregate metrics.
    public let enableAggregation: Bool
    
    /// Whether to enforce tag cardinality limits.
    public let enforceCardinality: Bool
    
    /// Default tags to apply to all metrics.
    public let defaultTags: [String: String]
    
    /// Namespace prefix for all metric names.
    public let namespace: String?
    
    // MARK: - Export Configuration
    
    /// Format metrics for specific backend types.
    public let exportFormat: ExportFormat
    
    /// Whether to include timestamps in exported metrics.
    public let includeTimestamps: Bool
    
    // MARK: - Initialization
    
    public init(
        maxDataPoints: Int = 10_000,
        maxMetricNames: Int = 1_000,
        maxTagCombinations: Int = 100,
        retentionPeriod: TimeInterval = 3600, // 1 hour
        aggregationWindows: [TimeInterval] = [60, 300, 900], // 1m, 5m, 15m
        computePercentiles: Bool = true,
        percentiles: [Double] = [0.5, 0.9, 0.95, 0.99, 0.999],
        enableAggregation: Bool = true,
        enforceCardinality: Bool = true,
        defaultTags: [String: String] = [:],
        namespace: String? = nil,
        exportFormat: ExportFormat = .standard,
        includeTimestamps: Bool = true
    ) {
        self.maxDataPoints = maxDataPoints
        self.maxMetricNames = maxMetricNames
        self.maxTagCombinations = maxTagCombinations
        self.retentionPeriod = retentionPeriod
        self.aggregationWindows = aggregationWindows
        self.computePercentiles = computePercentiles
        self.percentiles = percentiles
        self.enableAggregation = enableAggregation
        self.enforceCardinality = enforceCardinality
        self.defaultTags = defaultTags
        self.namespace = namespace
        self.exportFormat = exportFormat
        self.includeTimestamps = includeTimestamps
    }
    
    // MARK: - Preset Configurations
    
    /// Simple configuration for basic metrics without aggregation.
    public static let simple = MetricsConfiguration(
        maxDataPoints: 1_000,
        maxMetricNames: 100,
        computePercentiles: false,
        enableAggregation: false
    )
    
    /// Standard configuration with reasonable defaults.
    public static let standard = MetricsConfiguration()
    
    /// Advanced configuration for high-volume metrics.
    public static let advanced = MetricsConfiguration(
        maxDataPoints: 100_000,
        maxMetricNames: 10_000,
        maxTagCombinations: 1_000,
        retentionPeriod: 7200, // 2 hours
        aggregationWindows: [30, 60, 300, 900, 3600], // 30s, 1m, 5m, 15m, 1h
        computePercentiles: true,
        percentiles: [0.5, 0.75, 0.9, 0.95, 0.99, 0.999]
    )
    
    /// Development configuration with verbose settings.
    public static let development = MetricsConfiguration(
        maxDataPoints: 10_000,
        enforceCardinality: false,
        defaultTags: ["environment": "development"],
        includeTimestamps: true
    )
    
    /// Production configuration optimized for performance.
    public static let production = MetricsConfiguration(
        maxDataPoints: 50_000,
        maxMetricNames: 5_000,
        retentionPeriod: 1800, // 30 minutes
        enforceCardinality: true,
        defaultTags: ["environment": "production"],
        exportFormat: .optimized
    )
}

// MARK: - Supporting Types

/// Export format for metrics.
public enum ExportFormat: String, Sendable {
    /// Standard format with full metric details.
    case standard
    
    /// Optimized format with minimal overhead.
    case optimized
    
    /// OpenTelemetry compatible format.
    case openTelemetry
    
    /// Prometheus compatible format.
    case prometheus
    
    /// StatsD compatible format.
    case statsd
}

// MARK: - Builder Pattern

/// Builder for creating customized metrics configurations.
public struct MetricsConfigurationBuilder {
    private var config = MetricsConfiguration()
    
    public init() {}
    
    public func withMaxDataPoints(_ max: Int) -> MetricsConfigurationBuilder {
        var builder = self
        builder.config = MetricsConfiguration(
            maxDataPoints: max,
            maxMetricNames: config.maxMetricNames,
            maxTagCombinations: config.maxTagCombinations,
            retentionPeriod: config.retentionPeriod,
            aggregationWindows: config.aggregationWindows,
            computePercentiles: config.computePercentiles,
            percentiles: config.percentiles,
            enableAggregation: config.enableAggregation,
            enforceCardinality: config.enforceCardinality,
            defaultTags: config.defaultTags,
            namespace: config.namespace,
            exportFormat: config.exportFormat,
            includeTimestamps: config.includeTimestamps
        )
        return builder
    }
    
    public func withNamespace(_ namespace: String) -> MetricsConfigurationBuilder {
        var builder = self
        builder.config = MetricsConfiguration(
            maxDataPoints: config.maxDataPoints,
            maxMetricNames: config.maxMetricNames,
            maxTagCombinations: config.maxTagCombinations,
            retentionPeriod: config.retentionPeriod,
            aggregationWindows: config.aggregationWindows,
            computePercentiles: config.computePercentiles,
            percentiles: config.percentiles,
            enableAggregation: config.enableAggregation,
            enforceCardinality: config.enforceCardinality,
            defaultTags: config.defaultTags,
            namespace: namespace,
            exportFormat: config.exportFormat,
            includeTimestamps: config.includeTimestamps
        )
        return builder
    }
    
    public func withDefaultTags(_ tags: [String: String]) -> MetricsConfigurationBuilder {
        var builder = self
        builder.config = MetricsConfiguration(
            maxDataPoints: config.maxDataPoints,
            maxMetricNames: config.maxMetricNames,
            maxTagCombinations: config.maxTagCombinations,
            retentionPeriod: config.retentionPeriod,
            aggregationWindows: config.aggregationWindows,
            computePercentiles: config.computePercentiles,
            percentiles: config.percentiles,
            enableAggregation: config.enableAggregation,
            enforceCardinality: config.enforceCardinality,
            defaultTags: tags,
            namespace: config.namespace,
            exportFormat: config.exportFormat,
            includeTimestamps: config.includeTimestamps
        )
        return builder
    }
    
    public func build() -> MetricsConfiguration {
        return config
    }
}