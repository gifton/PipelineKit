import Foundation
import PipelineKitCore
#if canImport(os)
@preconcurrency import os
#endif

/// Runtime observability metrics for object pools.
///
/// Stores a bounded number of series and recent distribution observations.
/// Histogram and summary totals cover all accepted observations since reset; their
/// quantiles cover only the configured most recent observations.
public actor PoolObservability {
    // MARK: - Singleton
    
    /// Shared observability instance
    public static let shared = PoolObservability()
    
    private var counters: [MetricSeriesIdentity: UInt64] = [:]
    private var gauges: [MetricSeriesIdentity: Double] = [:]
    private var histograms: [MetricSeriesIdentity: PoolDistribution] = [:]
    private var summaries: [MetricSeriesIdentity: PoolDistribution] = [:]
    private var admittedSeries: Set<MetricSeriesIdentity> = []
    private let maximumSeries: Int
    private let distributionWindowSize: Int
    private let sleep: @Sendable (UInt64) async throws -> Void

    /// Rejected observations for unseen series after the series limit is reached.
    /// Repeated attempts for the same rejected identity each increment this count.
    public private(set) var droppedSeriesCount: UInt64 = 0

    /// Non-finite inputs or additions rejected before changing a gauge or distribution.
    public private(set) var invalidObservationCount: UInt64 = 0

    /// Counter additions that exceeded UInt64.max and were saturated at that value.
    public private(set) var saturatedCounterCount: UInt64 = 0

    private var exporters: [UUID: MetricExporter] = [:]
    private var exportTask: Task<Void, Never>?
    private var exportGeneration: UUID?

    /// Creates an independent pool metrics store.
    ///
    /// - Parameters:
    ///   - maximumSeries: Maximum identities across all metric kinds. Zero rejects
    ///     every observation. Existing series remain writable when the limit is full.
    ///   - distributionWindowSize: Positive number of observations retained per
    ///     distribution for exact recent-window quantiles. Totals remain cumulative.
    public init(maximumSeries: Int = 1000, distributionWindowSize: Int = 1000) {
        precondition(maximumSeries >= 0, "Maximum pool metric series must be nonnegative")
        precondition(distributionWindowSize > 0, "Distribution window size must be positive")
        self.maximumSeries = maximumSeries
        self.distributionWindowSize = distributionWindowSize
        self.sleep = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        maximumSeries: Int = 1000,
        distributionWindowSize: Int = 1000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        precondition(maximumSeries >= 0, "Maximum pool metric series must be nonnegative")
        precondition(distributionWindowSize > 0, "Distribution window size must be positive")
        self.maximumSeries = maximumSeries
        self.distributionWindowSize = distributionWindowSize
        self.sleep = sleep
    }

    deinit { exportTask?.cancel() }

    /// Adds to a cumulative counter, saturating at UInt64.max on overflow.
    public func incrementCounter(_ name: String, by value: UInt64 = 1, labels: [String: String]? = nil) {
        let key = identity(name, type: "counter", labels: labels)
        guard admit(key) else { return }
        let (sum, overflow) = counters[key, default: 0].addingReportingOverflow(value)
        counters[key] = overflow ? .max : sum
        if overflow { saturatedCounterCount = incremented(saturatedCounterCount) }
    }

    /// Returns the cumulative counter value, or zero when the series is absent.
    public func getCounter(_ name: String, labels: [String: String]? = nil) -> UInt64 {
        counters[identity(name, type: "counter", labels: labels)] ?? 0
    }

    /// Sets the latest finite gauge value; rejects nonfinite values before changing the series.
    public func setGauge(_ name: String, value: Double, labels: [String: String]? = nil) {
        guard value.isFinite else {
            invalidObservationCount = incremented(invalidObservationCount)
            return
        }
        let key = identity(name, type: "gauge", labels: labels)
        guard admit(key) else { return }
        gauges[key] = value
    }

    /// Adds a finite gauge delta, rejecting nonfinite or overflowing updates.
    public func incrementGauge(_ name: String, by value: Double = 1, labels: [String: String]? = nil) {
        let key = identity(name, type: "gauge", labels: labels)
        let updated = (gauges[key] ?? 0) + value
        guard value.isFinite, updated.isFinite else {
            invalidObservationCount = incremented(invalidObservationCount)
            return
        }
        guard admit(key) else { return }
        gauges[key] = updated
    }

    /// Subtracts a gauge delta using the same finite-value checks as `incrementGauge`.
    public func decrementGauge(_ name: String, by value: Double = 1, labels: [String: String]? = nil) {
        incrementGauge(name, by: -value, labels: labels)
    }

    /// Returns the latest gauge value, or nil when the series is absent.
    public func getGauge(_ name: String, labels: [String: String]? = nil) -> Double? {
        gauges[identity(name, type: "gauge", labels: labels)]
    }

    /// Rejects non-finite inputs and observations that would overflow the cumulative sum.
    public func recordHistogram(_ name: String, value: Double, labels: [String: String]? = nil) {
        guard value.isFinite else {
            invalidObservationCount = incremented(invalidObservationCount)
            return
        }
        let key = identity(name, type: "histogram", labels: labels)
        guard admit(key) else { return }
        if !histograms[key, default: PoolDistribution(capacity: distributionWindowSize)].record(value) {
            invalidObservationCount = incremented(invalidObservationCount)
        }
    }

    /// Returns lifetime histogram totals and recent-window quantiles, or nil when absent.
    public func getHistogram(_ name: String, labels: [String: String]? = nil) -> HistogramStats? {
        histograms[identity(name, type: "histogram", labels: labels)]?.histogramStatistics()
    }

    /// Rejects non-finite inputs and observations that would overflow the cumulative sum.
    public func recordSummary(_ name: String, value: Double, labels: [String: String]? = nil) {
        guard value.isFinite else {
            invalidObservationCount = incremented(invalidObservationCount)
            return
        }
        let key = identity(name, type: "summary", labels: labels)
        guard admit(key) else { return }
        if !summaries[key, default: PoolDistribution(capacity: distributionWindowSize)].record(value) {
            invalidObservationCount = incremented(invalidObservationCount)
        }
    }

    /// Returns lifetime summary totals and recent-window quantiles, or nil when absent.
    public func getSummary(_ name: String, labels: [String: String]? = nil) -> SummaryStats? {
        summaries[identity(name, type: "summary", labels: labels)]?.summaryStatistics()
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
        let (total, overflow) = available.addingReportingOverflow(inUse)
        // Preserve exact signed cancellation when the Int sum fits; the Double
        // fallback handles same-sign overflow (testPoolUtilizationHandlesNonnegativeCountsWhoseSumExceedsInt).
        let denominator = overflow ? Double(available) + Double(inUse) : Double(total)
        let utilization = denominator > 0 ? Double(inUse) / denominator * 100.0 : 0.0
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
    
    /// Starts exporting after the first interval. Repeated starts while active are ignored.
    public func startExporting(interval: TimeInterval = 60.0) {
        let nanoseconds = NumericDuration.nanoseconds(interval, positive: true)
        guard exportTask == nil else { return }
        let generation = UUID()
        exportGeneration = generation
        let sleep = self.sleep
        exportTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(nanoseconds) } catch { return }
                guard !Task.isCancelled,
                      await self?.exportMetrics(generation: generation) == true else { return }
            }
        }
    }

    /// Stops future periodic deliveries. An exporter already invoked may finish.
    /// Exporters and metric values remain registered for manual export or restart.
    public func stopExporting() {
        exportGeneration = nil
        exportTask?.cancel()
        exportTask = nil
    }

    /// Manually exports a snapshot independently of the periodic export lifecycle.
    public func exportMetrics() async {
        let snapshot = captureSnapshot()
        let handlers = Array(exporters.values)
        await withTaskGroup(of: Void.self) { group in
            for exporter in handlers {
                group.addTask { await exporter(snapshot) }
            }
        }
    }

    private func exportMetrics(generation: UUID) async -> Bool {
        guard exportGeneration == generation, !Task.isCancelled else { return false }
        let snapshot = captureSnapshot()
        let handlers = Array(exporters.values)
        await withTaskGroup(of: Void.self) { group in
            for exporter in handlers {
                group.addTask { [weak self] in
                    await self?.deliver(snapshot, to: exporter, generation: generation)
                }
            }
        }
        return exportGeneration == generation && !Task.isCancelled
    }

    private func deliver(_ snapshot: MetricsSnapshot, to exporter: MetricExporter, generation: UUID) async {
        guard exportGeneration == generation, !Task.isCancelled else { return }
        await exporter(snapshot)
    }

    /// Captures a value snapshot. Keys use quoted, escaped labels; names remain raw.
    public func captureSnapshot() -> MetricsSnapshot {
        var labels: [String: [String: String]] = [:]
        var names: [String: String] = [:]
        for key in admittedSeries {
            let displayKey = snapshotKey(key)
            labels[displayKey] = key.tags
            names[displayKey] = key.name
        }
        return MetricsSnapshot(
            timestamp: Date(),
            counters: Dictionary(uniqueKeysWithValues: counters.map { (snapshotKey($0.key), $0.value) }),
            gauges: Dictionary(uniqueKeysWithValues: gauges.map { (snapshotKey($0.key), $0.value) }),
            histograms: Dictionary(uniqueKeysWithValues: histograms.map { (snapshotKey($0.key), $0.value.histogramStatistics()) }),
            summaries: Dictionary(uniqueKeysWithValues: summaries.map { (snapshotKey($0.key), $0.value.summaryStatistics()) }),
            labels: labels,
            metricNames: names
        )
    }

    /// Clears stored series and all admission/observation diagnostics.
    public func reset() {
        counters.removeAll()
        gauges.removeAll()
        histograms.removeAll()
        summaries.removeAll()
        admittedSeries.removeAll()
        droppedSeriesCount = 0
        invalidObservationCount = 0
        saturatedCounterCount = 0
    }

    private func identity(_ name: String, type: String, labels: [String: String]?) -> MetricSeriesIdentity {
        MetricSeriesIdentity(name: name, type: type, unit: nil, tags: labels ?? [:])
    }

    private func admit(_ identity: MetricSeriesIdentity) -> Bool {
        if admittedSeries.contains(identity) { return true }
        guard admittedSeries.count < maximumSeries else {
            droppedSeriesCount = incremented(droppedSeriesCount)
            return false
        }
        admittedSeries.insert(identity)
        return true
    }

    private func incremented(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private func snapshotKey(_ identity: MetricSeriesIdentity) -> String {
        func quoted(_ value: String) -> String {
            "\"" + PrometheusTextFormat.escapeLabelValue(value) + "\""
        }
        let labels = identity.tags.sorted { $0.key < $1.key }.map { key, value in
            let label = PrometheusTextFormat.isValidLabelName(key) ? key : quoted(key)
            return "\(label)=\(quoted(value))"
        }.joined(separator: ",")
        // Invalid/raw punctuated names are quoted so braces in a name cannot alias labels.
        if PrometheusTextFormat.metricName(identity.name) == identity.name {
            return labels.isEmpty ? identity.name : "\(identity.name){\(labels)}"
        }
        return "{\(quoted(identity.name))\(labels.isEmpty ? "" : "," + labels)}"
    }
}

// MARK: - Supporting Types

/// Actor-owned distribution storage. Recording is O(1); a snapshot sorts at most capacity values.
struct PoolDistribution {
    private var values: [Double] = []
    private var nextIndex = 0
    private let capacity: Int
    private var count = 0
    private var sum: Double = 0
    private var minimum: Double = 0
    private var maximum: Double = 0

    var retainedSampleCount: Int { values.count }

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @discardableResult
    mutating func record(_ value: Double) -> Bool {
        let updatedSum = sum + value
        guard value.isFinite, updatedSum.isFinite else { return false }
        // swiftlint:disable:next empty_count -- count is a lifetime observation total, not a collection.
        if count == 0 { minimum = value; maximum = value }
        minimum = Swift.min(minimum, value)
        maximum = Swift.max(maximum, value)
        count = count == .max ? .max : count + 1
        sum = updatedSum
        if values.count < capacity {
            values.append(value)
        } else {
            values[nextIndex] = value
        }
        nextIndex = (nextIndex + 1) % capacity
        return true
    }

    func histogramStatistics() -> HistogramStats {
        let sorted = values.sorted()
        // swiftlint:disable:next empty_count -- count is a lifetime observation total, not a collection.
        return HistogramStats(count: count, sum: sum, mean: count > 0 ? sum / Double(count) : 0,
                              min: minimum, max: maximum, p50: percentile(sorted, 0.5),
                              p95: percentile(sorted, 0.95), p99: percentile(sorted, 0.99))
    }

    func summaryStatistics() -> SummaryStats {
        let sorted = values.sorted()
        return SummaryStats(count: count, sum: sum, p50: percentile(sorted, 0.5), p90: percentile(sorted, 0.9),
                            p95: percentile(sorted, 0.95), p99: percentile(sorted, 0.99), p999: percentile(sorted, 0.999))
    }

    private func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[Int(Double(sorted.count - 1) * quantile)]
    }
}

/// Lifetime aggregates with exact quantiles over the most recent configured window.
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

/// Lifetime count and sum with exact quantiles over the most recent configured window.
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
    let metricNames: [String: String]
}
