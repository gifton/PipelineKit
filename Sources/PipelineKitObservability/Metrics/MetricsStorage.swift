import Foundation
import PipelineKitCore

/// Bounded raw history and a separate cumulative view for Prometheus scraping.
///
/// History retention, draining, and pruning do not reset cumulative series.
/// Call `clear()` to reset both views and release admitted series identities.
public actor MetricsStorage: MetricRecorder {
    /// Saturating counts of rejected records and cumulative updates since clear.
    public struct Diagnostics: Sendable {
        /// Records rejected because the value is absent (except counters) or nonfinite.
        public fileprivate(set) var rejectedValues = 0
        /// New series rejected at the configured cardinality limit.
        public fileprivate(set) var droppedSeries = 0
        /// Negative counter increments or overflowing cumulative updates rejected
        /// from the scrape view. Their finite raw observations remain in history.
        public fileprivate(set) var rejectedPrometheusUpdates = 0
    }

    private struct StoredSnapshot {
        let snapshot: MetricSnapshot
        var ordinal: UInt64
    }

    private struct Series {
        var history: [StoredSnapshot] = []
        var scrape: PrometheusStoredValue?
    }

    private var series: [MetricSeriesIdentity: Series] = [:]
    private let maxSnapshotsPerMetric: Int
    private let maxSeries: Int
    private var totalMetricCount = 0
    private var ordinal: UInt64 = 0
    /// The current admission and numeric rejection counters.
    public private(set) var diagnostics = Diagnostics()

    /// Creates bounded history and cumulative storage with independent capacities.
    /// - Parameters:
    ///   - maxSnapshotsPerMetric: Raw observations retained per complete series.
    ///     Zero disables raw history while retaining scrape state.
    ///   - maxSeries: Maximum admitted identities until `clear()`. Zero disables
    ///     admission. At capacity, existing series still update.
    /// - Precondition: Both capacities are nonnegative.
    public init(maxSnapshotsPerMetric: Int = 1000, maxSeries: Int = 1000) {
        precondition(maxSnapshotsPerMetric >= 0, "maxSnapshotsPerMetric must be nonnegative")
        precondition(maxSeries >= 0, "maxSeries must be nonnegative")
        self.maxSnapshotsPerMetric = maxSnapshotsPerMetric
        self.maxSeries = maxSeries
    }

    /// Records a finite observation in raw history and updates its scrape series.
    /// Counter snapshots with no value represent one increment.
    public func record(_ snapshot: MetricSnapshot) {
        guard let value = snapshot.value ?? (snapshot.type == "counter" ? 1 : nil), value.isFinite else {
            increment(&diagnostics.rejectedValues)
            return
        }
        let identity = MetricSeriesIdentity(name: snapshot.name, type: snapshot.type,
                                            unit: snapshot.unit, tags: snapshot.tags)
        guard series[identity] != nil || series.count < maxSeries else {
            increment(&diagnostics.droppedSeries)
            return
        }
        renumberHistoryIfNeeded()
        var current = series[identity, default: Series()]
        if maxSnapshotsPerMetric > 0 {
            current.history.append(StoredSnapshot(snapshot: snapshot, ordinal: ordinal))
            ordinal += 1
            totalMetricCount += 1
            if current.history.count > maxSnapshotsPerMetric {
                current.history.removeFirst()
                totalMetricCount -= 1
            }
        }
        switch snapshot.type {
        case "counter":
            let previous: Double
            if case .counter(let total) = current.scrape { previous = total } else { previous = 0 }
            let total = previous + value
            if value >= 0 && total.isFinite {
                current.scrape = .counter(total)
            } else {
                increment(&diagnostics.rejectedPrometheusUpdates)
            }
        case "histogram":
            let previousSum: Double
            let previousCount: UInt64
            if case .histogram(let sum, let count) = current.scrape {
                previousSum = sum
                previousCount = count
            } else {
                previousSum = 0
                previousCount = 0
            }
            let sum = previousSum + value
            let (count, overflow) = previousCount.addingReportingOverflow(1)
            if sum.isFinite && !overflow {
                current.scrape = .histogram(sum: sum, count: count)
            } else {
                increment(&diagnostics.rejectedPrometheusUpdates)
            }
        default:
            current.scrape = .gauge(value)
        }
        series[identity] = current
    }

    /// Drains raw history; cumulative scrape values remain until `clear()`.
    public func drain() -> [MetricSnapshot] {
        let snapshots = getAll()
        for identity in series.keys { series[identity]?.history.removeAll(keepingCapacity: true) }
        totalMetricCount = 0
        return snapshots
    }

    /// Returns retained raw observations in recording order without draining them.
    public func getAll() -> [MetricSnapshot] {
        series.values.flatMap(\.history).sorted { $0.ordinal < $1.ordinal }.map(\.snapshot)
    }

    /// Returns retained observations for a name across all its series, in recording order.
    public func get(name: String) -> [MetricSnapshot] {
        series.filter { $0.key.name == name }.values.flatMap(\.history)
            .sorted { $0.ordinal < $1.ordinal }.map(\.snapshot)
    }

    /// Returns the last retained observation recorded under the supplied name.
    public func getLatest(name: String) -> MetricSnapshot? { get(name: name).last }

    /// Resets raw history, cumulative scrape values, cardinality, and diagnostics.
    public func clear() {
        series.removeAll()
        totalMetricCount = 0
        ordinal = 0
        diagnostics = Diagnostics()
    }

    /// The number of retained raw observations across all series.
    public var count: Int { totalMetricCount }

    /// Number of distinct names currently represented in raw history.
    public var uniqueMetricCount: Int {
        Set(series.filter { !$0.value.history.isEmpty }.keys.map(\.name)).count
    }

    /// Number of complete series identities admitted since the last clear.
    public var seriesCount: Int { series.count }

    /// Aggregates retained raw history by name, kind, unit, and exact tags.
    /// Counters are window sums, gauges use the last recorded value, and
    /// distributions produce the existing lower-index percentile gauges.
    /// Counter windows whose sum overflows are omitted.
    /// This historical view is not used for Prometheus cumulative counters.
    public func aggregate() -> [MetricSnapshot] {
        var aggregated: [MetricSnapshot] = []
        for (identity, current) in series {
            let snapshots = current.history.map(\.snapshot)
            guard let last = snapshots.last else { continue }
            switch identity.type {
            case "counter":
                var total: Double = 0
                var valid = true
                for snapshot in snapshots {
                    total += snapshot.value ?? 1
                    if !total.isFinite { valid = false; break }
                }
                if valid {
                    aggregated.append(MetricSnapshot(name: identity.name, type: identity.type, value: total,
                        timestamp: last.timestamp, tags: identity.tags, unit: identity.unit))
                }
            case "timer", "histogram":
                let values = snapshots.compactMap(\.value).sorted()
                for (suffix, percentile) in [("p50", 0.5), ("p95", 0.95), ("p99", 0.99)] where !values.isEmpty {
                    let index = Int(Double(values.count - 1) * percentile)
                    aggregated.append(MetricSnapshot(name: "\(identity.name).\(suffix)", type: "gauge",
                        value: values[index], timestamp: last.timestamp, tags: identity.tags, unit: identity.unit))
                }
            default:
                aggregated.append(last)
            }
        }
        return aggregated
    }

    /// Prunes raw history only. Ages extending before the Unix epoch retain all
    /// snapshots without an out-of-range integer conversion.
    /// - Precondition: `maxAge` is finite and nonnegative.
    public func pruneOlderThan(_ maxAge: TimeInterval) {
        precondition(maxAge.isFinite && maxAge >= 0, "maxAge must be finite and nonnegative")
        let cutoffSeconds = Date().timeIntervalSince1970 - maxAge
        guard cutoffSeconds >= 0 else { return }
        let cutoffMilliseconds = cutoffSeconds * 1000
        guard cutoffMilliseconds < Double(UInt64.max) else { return }
        let cutoff = UInt64(cutoffMilliseconds)
        for identity in series.keys {
            guard var current = series[identity] else { continue }
            let oldCount = current.history.count
            current.history.removeAll { $0.snapshot.timestamp <= cutoff }
            totalMetricCount -= oldCount - current.history.count
            series[identity] = current
        }
    }

    func prometheusSnapshots() -> [(identity: MetricSeriesIdentity, value: PrometheusStoredValue)] {
        series.compactMap { identity, current in current.scrape.map { (identity, $0) } }
    }

    private func increment(_ count: inout Int) {
        if count < Int.max { count += 1 }
    }

    private func renumberHistoryIfNeeded() {
        guard ordinal == UInt64.max else { return }
        let retained = series.values.flatMap(\.history).sorted { $0.ordinal < $1.ordinal }
        let positions = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element.ordinal, UInt64($0.offset)) })
        for identity in series.keys {
            guard var current = series[identity] else { continue }
            for index in current.history.indices {
                current.history[index].ordinal = positions[current.history[index].ordinal]!
            }
            series[identity] = current
        }
        ordinal = UInt64(retained.count)
    }
}

enum PrometheusStoredValue: Sendable {
    case counter(Double)
    case gauge(Double)
    case histogram(sum: Double, count: UInt64)
}
