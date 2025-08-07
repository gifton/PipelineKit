import PipelineKitCore
import Foundation

/// Standard implementation of MetricsCollector with configurable behavior.
///
/// This actor-based implementation provides thread-safe metrics collection with
/// automatic expiry, cardinality limits, and export-ready data format.
public actor StandardMetricsCollector: MetricsCollector {
    // MARK: - Properties
    
    private let configuration: MetricsConfiguration
    private var dataPoints: [MetricKey: [MetricDataPoint]] = [:]
    private var counters: [MetricKey: Double] = [:]
    private var gauges: [MetricKey: Double] = [:]
    private var metricNames: Set<String> = []
    private var lastCleanup: Date = Date()
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Types
    
    private struct MetricKey: Hashable {
        let name: String
        let tags: [String: String]
        
        var sortedTags: String {
            tags.sorted(by: { $0.key < $1.key })
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
    }
    
    // MARK: - Initialization
    
    public init(configuration: MetricsConfiguration = .standard) {
        self.configuration = configuration
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    // MARK: - MetricsCollector Protocol
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        // Start cleanup task on first use if needed
        if cleanupTask == nil && configuration.retentionPeriod > 0 {
            startCleanupTask()
        }
        
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        // Check cardinality limits
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        let key = MetricKey(name: finalName, tags: finalTags)
        counters[key, default: 0] += value
        
        // Record as data point
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .counter,
                value: counters[key] ?? value,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        // Start cleanup task on first use if needed
        if cleanupTask == nil && configuration.retentionPeriod > 0 {
            startCleanupTask()
        }
        
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        // Check cardinality limits
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        let key = MetricKey(name: finalName, tags: finalTags)
        gauges[key] = value
        
        // Record as data point
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .gauge,
                value: value,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        // Start cleanup task on first use if needed
        if cleanupTask == nil && configuration.retentionPeriod > 0 {
            startCleanupTask()
        }
        
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        // Check cardinality limits
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        // Record as data point
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .histogram,
                value: value,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        // Start cleanup task on first use if needed
        if cleanupTask == nil && configuration.retentionPeriod > 0 {
            startCleanupTask()
        }
        
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        // Check cardinality limits
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        // Convert to milliseconds for standard timer representation
        let milliseconds = duration * 1000
        
        // Record as data point
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .timer,
                value: milliseconds,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    public func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async {
        for metric in metrics {
            switch metric.type {
            case .counter:
                await recordCounter(metric.name, value: metric.value, tags: metric.tags)
            case .gauge:
                await recordGauge(metric.name, value: metric.value, tags: metric.tags)
            case .histogram:
                await recordHistogram(metric.name, value: metric.value, tags: metric.tags)
            case .timer:
                await recordTimer(metric.name, duration: metric.value, tags: metric.tags)
            }
        }
    }
    
    public func flush() async {
        // No-op - metrics are already persisted
    }
    
    public func getMetrics() async -> [MetricDataPoint] {
        // Perform cleanup before returning metrics
        performCleanup()
        
        var allMetrics: [MetricDataPoint] = []
        
        // Add all histogram/timer data points
        for points in dataPoints.values {
            allMetrics.append(contentsOf: points)
        }
        
        // Add current counter values
        for (key, value) in counters {
            allMetrics.append(
                MetricDataPoint(
                name: key.name,
                type: .counter,
                value: value,
                timestamp: Date(),
                tags: key.tags
                )
            )
        }
        
        // Add current gauge values
        for (key, value) in gauges {
            allMetrics.append(
                MetricDataPoint(
                name: key.name,
                type: .gauge,
                value: value,
                timestamp: Date(),
                tags: key.tags
                )
            )
        }
        
        return allMetrics.sorted { $0.timestamp < $1.timestamp }
    }
    
    public func reset() async {
        dataPoints.removeAll()
        counters.removeAll()
        gauges.removeAll()
        metricNames.removeAll()
        lastCleanup = Date()
    }
    
    // MARK: - Private Methods
    
    private func prefixedName(_ name: String) -> String {
        if let namespace = configuration.namespace {
            return "\(namespace).\(name)"
        }
        return name
    }
    
    private func mergedTags(_ tags: [String: String]) -> [String: String] {
        configuration.defaultTags.merging(tags) { _, new in new }
    }
    
    private func checkCardinality(name: String, tags: [String: String]) -> Bool {
        guard configuration.enforceCardinality else { return true }
        
        // Check metric name limit
        if !metricNames.contains(name) {
            if metricNames.count >= configuration.maxMetricNames {
                return false
            }
            metricNames.insert(name)
        }
        
        // Check tag combination limit
        let key = MetricKey(name: name, tags: tags)
        let tagCombinationsForMetric = dataPoints.keys.filter { $0.name == name }.count
        
        if !dataPoints.keys.contains(key) && tagCombinationsForMetric >= configuration.maxTagCombinations {
            return false
        }
        
        return true
    }
    
    private func recordDataPoint(_ dataPoint: MetricDataPoint) {
        let key = MetricKey(name: dataPoint.name, tags: dataPoint.tags)
        
        if dataPoints[key] == nil {
            dataPoints[key] = []
        }
        
        dataPoints[key]?.append(dataPoint)
        
        // Check data point limit
        if let count = dataPoints[key]?.count, count > configuration.maxDataPoints / max(metricNames.count, 1) {
            // Remove oldest data points
            dataPoints[key]?.removeFirst(count - configuration.maxDataPoints / max(metricNames.count, 1))
        }
        
        // Check total data points
        let totalDataPoints = dataPoints.values.reduce(0) { $0 + $1.count }
        if totalDataPoints > configuration.maxDataPoints {
            performCleanup()
        }
    }
    
    private func performCleanup() {
        let now = Date()
        let cutoffTime = now.addingTimeInterval(-configuration.retentionPeriod)
        
        // Remove expired data points
        for key in dataPoints.keys {
            dataPoints[key]?.removeAll { $0.timestamp < cutoffTime }
            
            // Remove empty entries
            if dataPoints[key]?.isEmpty == true {
                dataPoints.removeValue(forKey: key)
            }
        }
        
        lastCleanup = now
    }
    
    private func startCleanupTask() {
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.retentionPeriod * 0.1 * 1_000_000_000))
                performCleanup()
            }
        }
    }
}

// MARK: - Aggregation Support

public extension StandardMetricsCollector {
    /// Computes aggregated metrics for the specified time window.
    func getAggregatedMetrics(window: TimeInterval) async -> [AggregatedMetrics] {
        guard configuration.enableAggregation else { return [] }
        
        let metrics = await getMetrics()
        let now = Date()
        let windowStart = now.addingTimeInterval(-window)
        
        // Group metrics by name and tags
        var grouped: [MetricKey: [MetricDataPoint]] = [:]
        
        for metric in metrics where metric.timestamp >= windowStart {
            let key = MetricKey(name: metric.name, tags: metric.tags)
            grouped[key, default: []].append(metric)
        }
        
        // Compute statistics for each group
        var aggregated: [AggregatedMetrics] = []
        
        for (key, points) in grouped {
            guard let firstPoint = points.first else { continue }
            
            let timeWindow = TimeWindow(
                duration: window,
                startTime: windowStart,
                endTime: now
            )
            
            let statistics: MetricStatistics
            
            switch firstPoint.type {
            case .counter:
                let stats = computeCounterStatistics(points: points, window: window)
                statistics = .counter(stats)
                
            case .gauge:
                let stats = computeBasicStatistics(points: points)
                statistics = .basic(stats)
                
            case .histogram, .timer:
                if configuration.computePercentiles {
                    let stats = computeHistogramStatistics(
                        points: points,
                        percentiles: configuration.percentiles
                    )
                    statistics = .histogram(stats)
                } else {
                    let stats = computeBasicStatistics(points: points)
                    statistics = .basic(stats)
                }
            }
            
            aggregated.append(
                AggregatedMetrics(
                    name: key.name,
                    type: firstPoint.type,
                    window: timeWindow,
                    statistics: statistics,
                    tags: key.tags
                )
            )
        }
        
        return aggregated
    }
    
    private func computeBasicStatistics(points: [MetricDataPoint]) -> BasicStatistics {
        guard !points.isEmpty else {
            return BasicStatistics(count: 0, min: 0, max: 0, mean: 0, sum: 0)
        }
        
        let values = points.map { $0.value }
        let sum = values.reduce(0, +)
        let mean = sum / Double(values.count)
        
        return BasicStatistics(
            count: values.count,
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            mean: mean,
            sum: sum
        )
    }
    
    private func computeCounterStatistics(points: [MetricDataPoint], window: TimeInterval) -> CounterStatistics {
        guard !points.isEmpty else {
            return CounterStatistics(count: 0, rate: 0, increase: 0)
        }
        
        let sortedPoints = points.sorted { $0.timestamp < $1.timestamp }
        let firstValue = sortedPoints.first?.value ?? 0
        let lastValue = sortedPoints.last?.value ?? 0
        let increase = lastValue - firstValue
        let rate = window > 0 ? increase / window : 0
        
        return CounterStatistics(
            count: points.count,
            rate: rate,
            increase: increase
        )
    }
    
    private func computeHistogramStatistics(
        points: [MetricDataPoint],
        percentiles: [Double]
    ) -> HistogramStatistics {
        guard !points.isEmpty else {
            return HistogramStatistics(
                count: 0, min: 0, max: 0, mean: 0,
                p50: 0, p90: 0, p95: 0, p99: 0, p999: 0
            )
        }
        
        let values = points.map { $0.value }.sorted()
        let sum = values.reduce(0, +)
        let mean = sum / Double(values.count)
        
        func percentile(_ p: Double) -> Double {
            let index = Int(Double(values.count - 1) * p)
            return values[index]
        }
        
        return HistogramStatistics(
            count: values.count,
            min: values.first ?? 0,
            max: values.last ?? 0,
            mean: mean,
            p50: percentile(0.5),
            p90: percentile(0.9),
            p95: percentile(0.95),
            p99: percentile(0.99),
            p999: percentile(0.999)
        )
    }
}

// MARK: - Batch Recording Support

public extension StandardMetricsCollector {
    /// Record multiple metrics in a single operation for improved performance
    func recordBatch(_ metrics: [BatchMetric]) async {
        // Start cleanup task if needed
        if cleanupTask == nil && configuration.retentionPeriod > 0 {
            startCleanupTask()
        }
        
        // Process metrics in batch
        for metric in metrics {
            switch metric {
            case .counter(let name, let value, let tags):
                await recordCounterInternal(name, value: value, tags: tags)
            case .gauge(let name, let value, let tags):
                await recordGaugeInternal(name, value: value, tags: tags)
            case .histogram(let name, let value, let tags):
                await recordHistogramInternal(name, value: value, tags: tags)
            case .timer(let name, let duration, let tags):
                await recordTimerInternal(name, duration: duration, tags: tags)
            }
        }
        
        // Check total data points once at end
        let totalDataPoints = dataPoints.values.reduce(0) { $0 + $1.count }
        if totalDataPoints > configuration.maxDataPoints {
            performCleanup()
        }
    }
    
    // Internal methods that skip individual cleanup checks
    private func recordCounterInternal(_ name: String, value: Double, tags: [String: String]) async {
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        let key = MetricKey(name: finalName, tags: finalTags)
        counters[key, default: 0] += value
        
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .counter,
                value: counters[key] ?? value,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    private func recordGaugeInternal(_ name: String, value: Double, tags: [String: String]) async {
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        let key = MetricKey(name: finalName, tags: finalTags)
        gauges[key] = value
        
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .gauge,
                value: value,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    private func recordHistogramInternal(_ name: String, value: Double, tags: [String: String]) async {
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .histogram,
                value: value,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
    
    private func recordTimerInternal(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        let finalName = prefixedName(name)
        let finalTags = mergedTags(tags)
        
        guard checkCardinality(name: finalName, tags: finalTags) else { return }
        
        let milliseconds = duration * 1000
        
        recordDataPoint(
            MetricDataPoint(
                name: finalName,
                type: .timer,
                value: milliseconds,
                timestamp: Date(),
                tags: finalTags
            )
        )
    }
}

/// Batch metric type for efficient bulk recording
public enum BatchMetric: Sendable {
    case counter(name: String, value: Double, tags: [String: String])
    case gauge(name: String, value: Double, tags: [String: String])
    case histogram(name: String, value: Double, tags: [String: String])
    case timer(name: String, duration: TimeInterval, tags: [String: String])
}