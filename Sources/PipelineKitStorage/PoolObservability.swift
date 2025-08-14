import Foundation
#if canImport(os)
import os
#endif

/// Runtime observability metrics for object pools.
///
/// This provides production-ready metrics that can be exported to monitoring systems
/// like Prometheus, StatsD, DataDog, or CloudWatch.
public actor PoolObservability {
    // MARK: - Singleton
    
    /// Shared observability instance
    public static let shared = PoolObservability()
    
    // MARK: - Metric Types
    
    /// Counter metrics (monotonically increasing)
    private var counters: [String: UInt64] = [:]
    
    /// Gauge metrics (can go up or down)
    private var gauges: [String: Double] = [:]
    
    /// Histogram metrics (distribution of values)
    private var histograms: [String: Histogram] = [:]
    
    /// Summary metrics (percentiles)
    private var summaries: [String: Summary] = [:]
    
    /// Metric labels for dimensional data
    private var labels: [String: [String: String]] = [:]
    
    /// Export handlers
    private var exporters: [UUID: MetricExporter] = [:]
    
    /// Export interval
    private var exportInterval: TimeInterval = 60.0
    
    /// Export task
    private var exportTask: Task<Void, Never>?
    
    #if canImport(os)
    private let logger = Logger(subsystem: "PipelineKit", category: "PoolObservability")
    #endif
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Counter Operations
    
    /// Increments a counter metric
    public func incrementCounter(
        _ name: String,
        by value: UInt64 = 1,
        labels: [String: String]? = nil
    ) {
        let key = metricKey(name, labels: labels)
        counters[key, default: 0] += value
        
        if let labels = labels {
            self.labels[key] = labels
        }
    }
    
    /// Gets current counter value
    public func getCounter(_ name: String, labels: [String: String]? = nil) -> UInt64 {
        let key = metricKey(name, labels: labels)
        return counters[key] ?? 0
    }
    
    // MARK: - Gauge Operations
    
    /// Sets a gauge metric
    public func setGauge(
        _ name: String,
        value: Double,
        labels: [String: String]? = nil
    ) {
        let key = metricKey(name, labels: labels)
        gauges[key] = value
        
        if let labels = labels {
            self.labels[key] = labels
        }
    }
    
    /// Increments a gauge metric
    public func incrementGauge(
        _ name: String,
        by value: Double = 1.0,
        labels: [String: String]? = nil
    ) {
        let key = metricKey(name, labels: labels)
        gauges[key, default: 0.0] += value
        
        if let labels = labels {
            self.labels[key] = labels
        }
    }
    
    /// Decrements a gauge metric
    public func decrementGauge(
        _ name: String,
        by value: Double = 1.0,
        labels: [String: String]? = nil
    ) {
        let key = metricKey(name, labels: labels)
        gauges[key, default: 0.0] -= value
        
        if let labels = labels {
            self.labels[key] = labels
        }
    }
    
    /// Gets current gauge value
    public func getGauge(_ name: String, labels: [String: String]? = nil) -> Double? {
        let key = metricKey(name, labels: labels)
        return gauges[key]
    }
    
    // MARK: - Histogram Operations
    
    /// Records a value in a histogram
    public func recordHistogram(
        _ name: String,
        value: Double,
        labels: [String: String]? = nil
    ) {
        let key = metricKey(name, labels: labels)
        
        if histograms[key] == nil {
            histograms[key] = Histogram()
        }
        
        histograms[key]?.record(value)
        
        if let labels = labels {
            self.labels[key] = labels
        }
    }
    
    /// Gets histogram statistics
    public func getHistogram(_ name: String, labels: [String: String]? = nil) -> HistogramStats? {
        let key = metricKey(name, labels: labels)
        return histograms[key]?.statistics()
    }
    
    // MARK: - Summary Operations
    
    /// Records a value in a summary (for percentiles)
    public func recordSummary(
        _ name: String,
        value: Double,
        labels: [String: String]? = nil
    ) {
        let key = metricKey(name, labels: labels)
        
        if summaries[key] == nil {
            summaries[key] = Summary()
        }
        
        summaries[key]?.record(value)
        
        if let labels = labels {
            self.labels[key] = labels
        }
    }
    
    /// Gets summary percentiles
    public func getSummary(_ name: String, labels: [String: String]? = nil) -> SummaryStats? {
        let key = metricKey(name, labels: labels)
        return summaries[key]?.statistics()
    }
    
    // MARK: - Pool-Specific Metrics
    
    /// Records pool acquisition metrics
    public func recordPoolAcquisition(
        poolName: String,
        wasHit: Bool,
        latencyNanos: UInt64
    ) {
        // Hit/miss counters
        if wasHit {
            incrementCounter("pool_hits_total", labels: ["pool": poolName])
        } else {
            incrementCounter("pool_misses_total", labels: ["pool": poolName])
        }
        
        // Acquisition latency
        let latencyMs = Double(latencyNanos) / 1_000_000.0
        recordHistogram("pool_acquisition_latency_ms", value: latencyMs, labels: ["pool": poolName])
    }
    
    /// Records pool release metrics
    public func recordPoolRelease(
        poolName: String,
        wasEvicted: Bool,
        latencyNanos: UInt64
    ) {
        // Eviction counter
        if wasEvicted {
            incrementCounter("pool_evictions_total", labels: ["pool": poolName])
        }
        
        // Release latency
        let latencyMs = Double(latencyNanos) / 1_000_000.0
        recordHistogram("pool_release_latency_ms", value: latencyMs, labels: ["pool": poolName])
    }
    
    /// Updates pool size metrics
    public func updatePoolSize(
        poolName: String,
        available: Int,
        inUse: Int,
        maxSize: Int
    ) {
        setGauge("pool_available_objects", value: Double(available), labels: ["pool": poolName])
        setGauge("pool_in_use_objects", value: Double(inUse), labels: ["pool": poolName])
        setGauge("pool_max_size", value: Double(maxSize), labels: ["pool": poolName])
        
        // Utilization percentage
        let total = available + inUse
        let utilization = total > 0 ? Double(inUse) / Double(total) * 100.0 : 0.0
        setGauge("pool_utilization_percent", value: utilization, labels: ["pool": poolName])
    }
    
    /// Records shrink operation metrics
    public func recordPoolShrink(
        poolName: String,
        objectsRemoved: Int,
        wasThrottled: Bool,
        reason: String
    ) {
        incrementCounter("pool_shrink_operations_total", labels: [
            "pool": poolName,
            "reason": reason,
            "throttled": wasThrottled ? "true" : "false"
        ])
        
        if objectsRemoved > 0 {
            incrementCounter("pool_objects_shrunk_total", by: UInt64(objectsRemoved), labels: ["pool": poolName])
        }
    }
    
    /// Records memory pressure events
    public func recordMemoryPressure(
        level: MemoryPressureLevel,
        poolsAffected: Int,
        totalObjectsRemoved: Int
    ) {
        incrementCounter("memory_pressure_events_total", labels: ["level": String(describing: level)])
        
        recordHistogram("memory_pressure_pools_affected", value: Double(poolsAffected), labels: ["level": String(describing: level)])
        
        recordHistogram("memory_pressure_objects_removed", value: Double(totalObjectsRemoved), labels: ["level": String(describing: level)])
    }
    
    // MARK: - Export Management
    
    /// Metric exporter type
    public typealias MetricExporter = @Sendable (MetricsSnapshot) async -> Void
    
    /// Registers a metrics exporter
    @discardableResult
    public func registerExporter(_ exporter: @escaping MetricExporter) -> UUID {
        let id = UUID()
        exporters[id] = exporter
        return id
    }
    
    /// Unregisters a metrics exporter
    public func unregisterExporter(id: UUID) {
        exporters.removeValue(forKey: id)
    }
    
    /// Starts periodic metric export
    public func startExporting(interval: TimeInterval = 60.0) {
        self.exportInterval = interval
        
        guard exportTask == nil else { return }
        
        exportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.exportMetrics()
            }
        }
    }
    
    /// Stops metric export
    public func stopExporting() {
        exportTask?.cancel()
        exportTask = nil
    }
    
    /// Manually triggers metric export
    public func exportMetrics() async {
        let snapshot = captureSnapshot()
        
        await withTaskGroup(of: Void.self) { group in
            for exporter in exporters.values {
                group.addTask {
                    await exporter(snapshot)
                }
            }
        }
    }
    
    /// Captures current metrics snapshot
    public func captureSnapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            timestamp: Date(),
            counters: counters,
            gauges: gauges,
            histograms: histograms.mapValues { $0.statistics() },
            summaries: summaries.mapValues { $0.statistics() },
            labels: labels
        )
    }
    
    /// Resets all metrics
    public func reset() {
        counters.removeAll()
        gauges.removeAll()
        histograms.removeAll()
        summaries.removeAll()
        labels.removeAll()
    }
    
    // MARK: - Private Helpers
    
    private func metricKey(_ name: String, labels: [String: String]?) -> String {
        guard let labels = labels, !labels.isEmpty else {
            return name
        }
        
        let sortedLabels = labels.sorted { $0.key < $1.key }
        let labelStr = sortedLabels.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(name){\(labelStr)}"
    }
}

// MARK: - Supporting Types

/// Histogram for tracking value distributions
private final class Histogram: @unchecked Sendable {
    private var values: [Double] = []
    private let lock = NSLock()
    
    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
    
    func statistics() -> HistogramStats {
        lock.lock()
        defer { lock.unlock() }
        
        guard !values.isEmpty else {
            return HistogramStats(
                count: 0,
                sum: 0,
                mean: 0,
                min: 0,
                max: 0,
                p50: 0,
                p95: 0,
                p99: 0
            )
        }
        
        let sorted = values.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let mean = sum / Double(count)
        
        return HistogramStats(
            count: count,
            sum: sum,
            mean: mean,
            min: sorted.first!,
            max: sorted.last!,
            p50: percentile(sorted, 0.5),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99)
        )
    }
    
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
}

/// Summary for tracking percentiles with sliding window
private final class Summary: @unchecked Sendable {
    private var values: [Double] = []
    private let maxSize = 1000
    private let lock = NSLock()
    
    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        values.append(value)
        if values.count > maxSize {
            values.removeFirst()
        }
    }
    
    func statistics() -> SummaryStats {
        lock.lock()
        defer { lock.unlock() }
        
        guard !values.isEmpty else {
            return SummaryStats(
                count: 0,
                sum: 0,
                p50: 0,
                p90: 0,
                p95: 0,
                p99: 0,
                p999: 0
            )
        }
        
        let sorted = values.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        
        return SummaryStats(
            count: count,
            sum: sum,
            p50: percentile(sorted, 0.5),
            p90: percentile(sorted, 0.9),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99),
            p999: percentile(sorted, 0.999)
        )
    }
    
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
}

/// Histogram statistics
public struct HistogramStats: Sendable {
    public let count: Int
    public let sum: Double
    public let mean: Double
    public let min: Double
    public let max: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double
}

/// Summary statistics
public struct SummaryStats: Sendable {
    public let count: Int
    public let sum: Double
    public let p50: Double
    public let p90: Double
    public let p95: Double
    public let p99: Double
    public let p999: Double
}

/// Metrics snapshot for export
public struct MetricsSnapshot: Sendable {
    public let timestamp: Date
    public let counters: [String: UInt64]
    public let gauges: [String: Double]
    public let histograms: [String: HistogramStats]
    public let summaries: [String: SummaryStats]
    public let labels: [String: [String: String]]
}

// MARK: - Prometheus Format Export

public extension MetricsSnapshot {
    /// Exports metrics in Prometheus format
    func prometheusFormat() -> String {
        var lines: [String] = []
        
        // Counters
        for (key, value) in counters {
            lines.append("\(key) \(value)")
        }
        
        // Gauges
        for (key, value) in gauges {
            lines.append("\(key) \(value)")
        }
        
        // Histograms
        for (key, stats) in histograms {
            lines.append("\(key)_count \(stats.count)")
            lines.append("\(key)_sum \(stats.sum)")
            lines.append("\(key){quantile=\"0.5\"} \(stats.p50)")
            lines.append("\(key){quantile=\"0.95\"} \(stats.p95)")
            lines.append("\(key){quantile=\"0.99\"} \(stats.p99)")
        }
        
        // Summaries
        for (key, stats) in summaries {
            lines.append("\(key)_count \(stats.count)")
            lines.append("\(key)_sum \(stats.sum)")
            lines.append("\(key){quantile=\"0.5\"} \(stats.p50)")
            lines.append("\(key){quantile=\"0.9\"} \(stats.p90)")
            lines.append("\(key){quantile=\"0.95\"} \(stats.p95)")
            lines.append("\(key){quantile=\"0.99\"} \(stats.p99)")
            lines.append("\(key){quantile=\"0.999\"} \(stats.p999)")
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Exports metrics in StatsD format
    func statsdFormat() -> [String] {
        var lines: [String] = []
        
        // Counters
        for (key, value) in counters {
            lines.append("\(key):\(value)|c")
        }
        
        // Gauges
        for (key, value) in gauges {
            lines.append("\(key):\(value)|g")
        }
        
        // Histograms (as timers in StatsD)
        for (key, stats) in histograms {
            lines.append("\(key):\(stats.mean)|ms")
        }
        
        return lines
    }
}