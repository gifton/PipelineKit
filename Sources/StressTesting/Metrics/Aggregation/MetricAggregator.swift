import PipelineKitObservability
import Foundation
import PipelineKit

/// High-level aggregation system for metrics.
///
/// MetricAggregator provides a complete aggregation solution that:
/// - Manages time windows automatically
/// - Supports multiple aggregation intervals
/// - Provides efficient querying
/// - Handles memory management
///
/// ## Usage Example
/// ```swift
/// let aggregator = MetricAggregator()
/// await aggregator.start()
///
/// // Add metrics
/// await aggregator.add(.gauge("cpu.usage", value: 75.0))
/// await aggregator.add(.counter("requests.total", value: 100))
///
/// // Query aggregated data
/// let query = MetricQuery(
///     namePattern: "cpu.*",
///     timeRange: Date()...Date(),
///     windows: [60, 300] // 1min and 5min
/// )
/// let results = await aggregator.query(query)
/// ```
public actor MetricAggregator {
    /// Configuration for the aggregator.
    public struct Configuration: Sendable {
        /// Supported aggregation windows.
        public let windows: Set<TimeInterval>
        
        /// Maximum windows to keep per metric.
        public let maxWindowsPerMetric: Int
        
        /// How often to rotate windows.
        public let rotationInterval: TimeInterval
        
        /// Whether to start automatically.
        public let autoStart: Bool
        
        public init(
            windows: Set<TimeInterval> = [60, 300, 900], // 1min, 5min, 15min
            maxWindowsPerMetric: Int = 60,
            rotationInterval: TimeInterval = 10,
            autoStart: Bool = false
        ) {
            self.windows = windows
            self.maxWindowsPerMetric = maxWindowsPerMetric
            self.rotationInterval = rotationInterval
            self.autoStart = autoStart
        }
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private let windowManager: TimeWindowManager
    private var isRunning = false
    
    // Statistics
    private var totalProcessed: Int = 0
    private var lastProcessedTime: Date?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.windowManager = TimeWindowManager(
            configuration: TimeWindowManager.Configuration(
                windowDurations: configuration.windows,
                maxWindowsPerDuration: configuration.maxWindowsPerMetric,
                rotationCheckInterval: configuration.rotationInterval
            )
        )
        
        if configuration.autoStart {
            Task {
                await self.start()
            }
        }
    }
    
    // MARK: - Lifecycle
    
    /// Starts the aggregation system.
    public func start() async {
        guard !isRunning else { return }
        
        isRunning = true
        await windowManager.start()
    }
    
    /// Stops the aggregation system.
    public func stop() async {
        guard isRunning else { return }
        
        isRunning = false
        await windowManager.stop()
    }
    
    // MARK: - Data Input
    
    /// Adds a single metric sample.
    public func add(_ sample: MetricDataPoint) async {
        guard isRunning else { return }
        
        await windowManager.add(sample)
        totalProcessed += 1
        lastProcessedTime = Date()
    }
    
    /// Adds multiple metric samples.
    public func addBatch(_ samples: [MetricDataPoint]) async {
        guard isRunning else { return }
        
        for sample in samples {
            await windowManager.add(sample)
        }
        
        totalProcessed += samples.count
        lastProcessedTime = Date()
    }
    
    // MARK: - Querying
    
    /// Queries aggregated metrics.
    public func query(_ query: MetricQuery) async -> MetricQueryResult {
        let startTime = Date()
        
        let metrics = await windowManager.query(query)
        
        let queryTime = Date().timeIntervalSince(startTime)
        
        return MetricQueryResult(
            metrics: metrics,
            queryTime: queryTime,
            pointsProcessed: metrics.reduce(0) { $0 + $1.statistics.count }
        )
    }
    
    /// Gets metrics for a specific name and window.
    public func get(
        metric: String,
        window: TimeInterval,
        at timestamp: Date = Date()
    ) async -> PipelineKitObservability.AggregatedMetrics? {
        let query = MetricQuery(
            namePattern: metric,
            timeRange: timestamp.addingTimeInterval(-window)...timestamp,
            windows: [window]
        )
        
        let result = await self.query(query)
        return result.metrics.last
    }
    
    /// Lists all available metrics.
    public func listMetrics() async -> [MetricInfo] {
        // Get unique metric names from recent queries
        let endTime = Date()
        let startTime = endTime.addingTimeInterval(-300) // Last 5 minutes
        
        let query = MetricQuery(
            namePattern: "*",
            timeRange: startTime...endTime,
            windows: [60] // Use 1-minute window for listing
        )
        
        let result = await windowManager.query(query)
        
        // Group by metric name and type
        let grouped = Dictionary(grouping: result) { $0.name }
        
        return grouped.map { name, metrics in
            let metric = metrics.first!
            return MetricInfo(
                name: name,
                type: metric.type,
                dataPoints: metrics.reduce(0) { $0 + $1.statistics.count },
                lastUpdated: metric.timestamp
            )
        }.sorted { $0.name < $1.name }
    }
    
    // MARK: - Statistics
    
    /// Returns aggregation statistics.
    public func statistics() async -> AggregationStatistics {
        let windowStats = await windowManager.statistics()
        
        return AggregationStatistics(
            isRunning: isRunning,
            totalProcessed: totalProcessed,
            lastProcessedTime: lastProcessedTime,
            metricCount: windowStats.metricCount,
            windowCount: windowStats.totalWindows,
            dataPointCount: windowStats.totalDataPoints,
            configuredWindows: configuration.windows
        )
    }
    
    // MARK: - Convenience Methods
    
    /// Gets the latest value for a gauge metric.
    public func latestGauge(_ metric: String) async -> Double? {
        guard let aggregated = await get(metric: metric, window: 60) else {
            return nil
        }
        
        if case .basic(let stats) = aggregated.statistics {
            return stats.lastValue
        }
        
        return nil
    }
    
    /// Gets the rate for a counter metric.
    public func counterRate(_ metric: String, window: TimeInterval = 60) async -> Double? {
        guard let aggregated = await get(metric: metric, window: window) else {
            return nil
        }
        
        if case .counter(let stats) = aggregated.statistics {
            return stats.rate
        }
        
        return nil
    }
    
    /// Gets percentiles for a histogram metric.
    public func histogramPercentiles(_ metric: String, window: TimeInterval = 60) async -> PipelineKitObservability.HistogramStatistics? {
        guard let aggregated = await get(metric: metric, window: window) else {
            return nil
        }
        
        if case .histogram(let stats) = aggregated.statistics {
            return stats
        }
        
        return nil
    }
}

// MARK: - Supporting Types

/// Information about a tracked metric.
public struct MetricInfo: Sendable {
    public let name: String
    public let type: MetricType
    public let dataPoints: Int
    public let lastUpdated: Date
}

/// Statistics about the aggregation system.
public struct AggregationStatistics: Sendable {
    public let isRunning: Bool
    public let totalProcessed: Int
    public let lastProcessedTime: Date?
    public let metricCount: Int
    public let windowCount: Int
    public let dataPointCount: Int
    public let configuredWindows: Set<TimeInterval>
}

// MARK: - Integration Helpers

public extension MetricAggregator {
    /// Creates an aggregator integrated with a MetricCollector.
    static func integrated(
        with collector: MetricCollector,
        configuration: Configuration = Configuration()
    ) async -> MetricAggregator {
        let aggregator = MetricAggregator(configuration: configuration)
        await aggregator.start()
        
        // Connect to collector's stream
        Task {
            for await sample in await collector.stream() {
                await aggregator.add(sample)
            }
        }
        
        return aggregator
    }
}
