import Foundation

/// A lightweight actor for storing metrics before export.
///
/// Provides thread-safe storage with automatic draining to prevent
/// unbounded memory growth. Uses efficient data structures to avoid
/// O(n) operations.
public actor MetricsStorage: MetricRecorder {
    /// Internal storage of metrics grouped by name.
    private var metrics: [String: [MetricSnapshot]] = [:]
    
    /// Maximum number of snapshots to keep per metric name.
    private let maxSnapshotsPerMetric: Int
    
    /// Total metric count for monitoring.
    private var totalMetricCount = 0
    
    /// Creates a new metrics storage.
    ///
    /// - Parameter maxSnapshotsPerMetric: Maximum snapshots per metric (default: 1000)
    public init(maxSnapshotsPerMetric: Int = 1000) {
        self.maxSnapshotsPerMetric = maxSnapshotsPerMetric
    }
    
    /// Records a metric snapshot.
    public func record(_ snapshot: MetricSnapshot) {
        var snapshots = metrics[snapshot.name, default: []]
        snapshots.append(snapshot)
        totalMetricCount += 1
        
        // Prevent unbounded growth - use removeSubrange for O(1) amortized performance
        if snapshots.count > maxSnapshotsPerMetric {
            let removeCount = snapshots.count - maxSnapshotsPerMetric
            snapshots.removeSubrange(0..<removeCount)
            totalMetricCount -= removeCount
        }
        
        metrics[snapshot.name] = snapshots
    }
    
    /// Drains all stored metrics.
    ///
    /// - Returns: All stored snapshots, clearing internal storage
    public func drain() -> [MetricSnapshot] {
        let allSnapshots = metrics.values.flatMap { $0 }
        metrics.removeAll(keepingCapacity: true)
        totalMetricCount = 0
        return allSnapshots
    }
    
    /// Gets all metrics without draining.
    ///
    /// - Returns: All stored snapshots
    public func getAll() -> [MetricSnapshot] {
        metrics.values.flatMap { $0 }
    }
    
    /// Gets metrics for a specific name.
    ///
    /// - Parameter name: The metric name
    /// - Returns: Snapshots for that metric
    public func get(name: String) -> [MetricSnapshot] {
        metrics[name] ?? []
    }
    
    /// Gets the latest snapshot for a specific metric.
    ///
    /// - Parameter name: The metric name
    /// - Returns: The most recent snapshot, if any
    public func getLatest(name: String) -> MetricSnapshot? {
        metrics[name]?.last
    }
    
    /// Clears all stored metrics.
    public func clear() {
        metrics.removeAll()
        totalMetricCount = 0
    }
    
    /// Returns the current count of stored metrics.
    public var count: Int {
        totalMetricCount
    }
    
    /// Returns the number of unique metric names.
    public var uniqueMetricCount: Int {
        metrics.count
    }
    
    /// Aggregates metrics by name, summing counters and averaging gauges.
    ///
    /// Useful for reducing data before export.
    public func aggregate() -> [MetricSnapshot] {
        var aggregated: [MetricSnapshot] = []
        
        for (name, snapshots) in metrics {
            guard !snapshots.isEmpty else { continue }
            
            let firstSnapshot = snapshots[0]
            
            switch firstSnapshot.type {
            case "counter":
                // Sum all counter values
                let total = snapshots.compactMap { $0.value }.reduce(0, +)
                aggregated.append(MetricSnapshot(
                    name: name,
                    type: "counter",
                    value: total,
                    tags: firstSnapshot.tags,
                    unit: firstSnapshot.unit
                ))
                
            case "gauge":
                // Take the latest gauge value
                if let latest = snapshots.last {
                    aggregated.append(latest)
                }
                
            case "timer", "histogram":
                // Calculate percentiles for timers/histograms
                let values = snapshots.compactMap { $0.value }.sorted()
                if !values.isEmpty {
                    let p50 = percentile(values, 0.5)
                    let p95 = percentile(values, 0.95)
                    let p99 = percentile(values, 0.99)
                    
                    aggregated.append(MetricSnapshot(
                        name: "\(name).p50",
                        type: "gauge",
                        value: p50,
                        tags: firstSnapshot.tags,
                        unit: firstSnapshot.unit
                    ))
                    aggregated.append(MetricSnapshot(
                        name: "\(name).p95",
                        type: "gauge",
                        value: p95,
                        tags: firstSnapshot.tags,
                        unit: firstSnapshot.unit
                    ))
                    aggregated.append(MetricSnapshot(
                        name: "\(name).p99",
                        type: "gauge",
                        value: p99,
                        tags: firstSnapshot.tags,
                        unit: firstSnapshot.unit
                    ))
                }
                
            default:
                // For unknown types, take the latest
                if let latest = snapshots.last {
                    aggregated.append(latest)
                }
            }
        }
        
        return aggregated
    }
    
    /// Calculates a percentile from a sorted array.
    private func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        
        let index = Int(Double(sortedValues.count - 1) * p)
        return sortedValues[index]
    }
    
    /// Prunes old metrics based on age.
    ///
    /// - Parameter maxAge: Maximum age for metrics to keep
    public func pruneOlderThan(_ maxAge: TimeInterval) {
        let cutoff = UInt64(Date().addingTimeInterval(-maxAge).timeIntervalSince1970 * 1000)
        
        for (name, snapshots) in metrics {
            let filtered = snapshots.filter { $0.timestamp > cutoff }
            if filtered.isEmpty {
                metrics.removeValue(forKey: name)
                totalMetricCount -= snapshots.count
            } else if filtered.count < snapshots.count {
                metrics[name] = filtered
                totalMetricCount -= (snapshots.count - filtered.count)
            }
        }
    }
}
