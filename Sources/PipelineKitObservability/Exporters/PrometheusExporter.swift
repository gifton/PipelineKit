import Foundation
import PipelineKitCore

/// Exports a cumulative Prometheus text 0.0.4 scrape from `MetricsStorage`.
///
/// Counters accumulate until storage is cleared, gauges and timers retain their
/// latest value, and histograms expose cumulative sum/count and the required
/// `+Inf` bucket. Timers retain the existing milliseconds gauge representation.
/// Raw history retention, draining, and pruning do not reset this scrape view.
public actor PrometheusExporter {
    /// Why a stored series was omitted from an exposition.
    public enum RejectionReason: String, Sendable {
        /// The normalized name does not match the legacy metric identifier grammar.
        case invalidMetricName
        /// A label key does not match the legacy label identifier grammar.
        case invalidLabelName
        /// A label uses Prometheus's internal prefix or a generated bucket dimension.
        case reservedLabelName
        /// Distinct names, kinds, or units map to overlapping wire families.
        case conflictingDefinition
        /// Distinct stored label dictionaries identify the same Prometheus sample.
        case conflictingSample
        /// A timer explicitly declares a unit other than milliseconds.
        case unsupportedUnit
    }

    /// A rejected series and the reason it could not be represented.
    public struct Rejection: Sendable {
        /// The original metric name before normalization and suffixing.
        public let metricName: String
        /// The validation or identity conflict that prevented export.
        public let reason: RejectionReason
    }

    /// Valid exposition text together with bounded series rejection diagnostics.
    public struct ExportResult: Sendable {
        /// The accepted families in Prometheus text exposition format.
        public let text: String
        /// One entry per rejected stored series, bounded by storage's series cap.
        public let rejectedSeries: [Rejection]
    }

    private struct Definition: Hashable {
        let name: String
        let type: String
        let unit: String?
    }

    private struct Candidate {
        let identity: MetricSeriesIdentity
        let value: PrometheusStoredValue
        let base: String
        let family: String

        var definition: Definition {
            Definition(name: identity.name, type: identity.type, unit: identity.unit)
        }

        var sampleNames: [String] {
            if identity.type == "histogram" { return [family + "_bucket", family + "_sum", family + "_count"] }
            return [family]
        }
    }

    private struct SampleIdentity: Hashable {
        let name: String
        let tags: [String: String]
    }

    private let metricsStorage: MetricsStorage

    /// Creates an exporter reading the storage's cumulative scrape view.
    public init(metricsStorage: MetricsStorage) { self.metricsStorage = metricsStorage }

    /// Returns valid families. Use `exportWithDiagnostics()` to inspect omitted
    /// series, and storage diagnostics to inspect rejected numeric updates.
    public func export() async -> String { await exportWithDiagnostics().text }

    /// Alias for the cumulative scrape; historical percentile gauges remain
    /// available through `MetricsStorage.aggregate()`.
    public func exportAggregated() async -> String { await export() }

    /// Invalid names and labels are rejected. Distinct definitions that collide
    /// after dot/dash normalization, suffixing, or generated histogram naming
    /// are all rejected, independent of record or dictionary iteration order.
    public func exportWithDiagnostics() async -> ExportResult {
        let snapshots = await metricsStorage.prometheusSnapshots()
        var rejected: [MetricSeriesIdentity: RejectionReason] = [:]
        var candidates: [Candidate] = []
        for (identity, value) in snapshots {
            guard let base = PrometheusTextFormat.metricName(identity.name) else {
                rejected[identity] = .invalidMetricName
                continue
            }
            // Snapshot timer factories produce milliseconds. A legacy nil unit
            // retains that convention; an explicit different unit is not relabeled.
            if identity.type == "timer", let unit = identity.unit, unit != "ms" {
                rejected[identity] = .unsupportedUnit
                continue
            }
            if identity.tags.keys.contains(where: { $0.hasPrefix("__") }) ||
                (identity.type == "histogram" && identity.tags["le"] != nil) {
                rejected[identity] = .reservedLabelName
                continue
            }
            guard identity.tags.keys.allSatisfy(PrometheusTextFormat.isValidLabelName) else {
                rejected[identity] = .invalidLabelName
                continue
            }
            let family: String
            switch identity.type {
            case "counter": family = base + "_total"
            case "timer": family = base + "_milliseconds"
            default: family = base
            }
            candidates.append(Candidate(identity: identity, value: value, base: base, family: family))
        }

        var baseDefinitions: [String: Set<Definition>] = [:]
        var wireDefinitions: [String: Set<Definition>] = [:]
        for candidate in candidates {
            baseDefinitions[candidate.base, default: []].insert(candidate.definition)
            for name in Set(candidate.sampleNames + [candidate.family]) {
                wireDefinitions[name, default: []].insert(candidate.definition)
            }
        }
        for candidate in candidates {
            if baseDefinitions[candidate.base, default: []].count > 1 ||
                (candidate.sampleNames + [candidate.family]).contains(where: { wireDefinitions[$0, default: []].count > 1 }) {
                rejected[candidate.identity] = .conflictingDefinition
            }
        }

        // Prometheus treats an empty label value as equivalent to an absent
        // label. Test: testEmptyAndAbsentLabelsDoNotProduceEquivalentDuplicateSamples.
        var samples: [SampleIdentity: [MetricSeriesIdentity]] = [:]
        for candidate in candidates where rejected[candidate.identity] == nil {
            let labels = candidate.identity.tags.filter { !$0.value.isEmpty }
            for name in candidate.sampleNames {
                samples[SampleIdentity(name: name, tags: labels), default: []].append(candidate.identity)
            }
        }
        for identities in samples.values where identities.count > 1 {
            for identity in identities { rejected[identity] = .conflictingSample }
        }

        let accepted = candidates.filter { rejected[$0.identity] == nil }
        let families = Dictionary(grouping: accepted, by: \.family)
        var output = ""
        for (family, metrics) in families.sorted(by: { $0.key < $1.key }) {
            guard let first = metrics.first else { continue }
            let type: String
            switch first.identity.type {
            case "counter": type = "counter"
            case "histogram": type = "histogram"
            default: type = "gauge"
            }
            output += "# TYPE \(family) \(type)\n"
            output += metrics.flatMap(format).sorted().joined(separator: "\n") + "\n\n"
        }
        let diagnostics = rejected.map { Rejection(metricName: $0.key.name, reason: $0.value) }
            .sorted { ($0.metricName, $0.reason.rawValue) < ($1.metricName, $1.reason.rawValue) }
        return ExportResult(text: output, rejectedSeries: diagnostics)
    }

    private func format(_ candidate: Candidate) -> [String] {
        let labels = formatTags(candidate.identity.tags)
        switch candidate.value {
        case .counter(let value), .gauge(let value):
            return ["\(candidate.family)\(labels) \(PrometheusTextFormat.value(value))"]
        case .histogram(let sum, let count):
            var bucketLabels = candidate.identity.tags
            bucketLabels["le"] = "+Inf"
            return [
                "\(candidate.family)_bucket\(formatTags(bucketLabels)) \(count)",
                "\(candidate.family)_sum\(labels) \(PrometheusTextFormat.value(sum))",
                "\(candidate.family)_count\(labels) \(count)"
            ]
        }
    }

    private func formatTags(_ tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "" }
        return "{" + tags.sorted(by: { $0.key < $1.key }).map {
            "\($0.key)=\"\(PrometheusTextFormat.escapeLabelValue($0.value))\""
        }.joined(separator: ",") + "}"
    }
}
