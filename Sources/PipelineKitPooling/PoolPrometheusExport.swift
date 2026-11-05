import PipelineKitCore

/// A Prometheus scrape and the number of stored series omitted from it.
public struct PoolPrometheusExportResult: Sendable {
    /// Accepted metric families in Prometheus text exposition format.
    public let text: String
    /// Number of snapshot series omitted because of invalid data or wire identity conflicts.
    public let rejectedSeriesCount: Int
}

public extension MetricsSnapshot {
    /// Exports cumulative scalar values and windowed distribution quantiles.
    /// Pool distributions use `summary` families: count/sum cover their lifetime,
    /// while quantiles cover the configured most recent observation window.
    func prometheusFormat() -> String { prometheusFormatWithDiagnostics().text }

    /// Rejects malformed names/labels and all definitions whose normalized or
    /// generated sample names collide. No caller-provided labels are overwritten.
    func prometheusFormatWithDiagnostics() -> PoolPrometheusExportResult {
        var candidates: [PoolPrometheusCandidate] = []
        for (key, value) in counters {
            candidates.append(.init(key: key, name: metricNames[key] ?? key, kind: "counter",
                                    labels: labels[key] ?? [:], value: .counter(value)))
        }
        for (key, value) in gauges {
            candidates.append(.init(key: key, name: metricNames[key] ?? key, kind: "gauge",
                                    labels: labels[key] ?? [:], value: .gauge(value)))
        }
        for (key, value) in histograms {
            candidates.append(.init(key: key, name: metricNames[key] ?? key, kind: "histogram",
                                    labels: labels[key] ?? [:], value: .distribution(
                                        count: value.count, sum: value.sum,
                                        quantiles: [("0.5", value.p50), ("0.95", value.p95), ("0.99", value.p99)])))
        }
        for (key, value) in summaries {
            candidates.append(.init(key: key, name: metricNames[key] ?? key, kind: "summary",
                                    labels: labels[key] ?? [:], value: .distribution(
                                        count: value.count, sum: value.sum,
                                        quantiles: [("0.5", value.p50), ("0.9", value.p90), ("0.95", value.p95),
                                                    ("0.99", value.p99), ("0.999", value.p999)])))
        }
        var rejected = Set<Int>()
        var families: [String: Set<PoolPrometheusDefinition>] = [:]
        var names: [String: Set<PoolPrometheusDefinition>] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard candidate.family != nil, candidate.labels.keys.allSatisfy(PrometheusTextFormat.isValidLabelName),
                  candidate.value.isFinite,
                  !(candidate.value.isDistribution && candidate.labels["quantile"] != nil) else {
                rejected.insert(index)
                continue
            }
            families[candidate.family!, default: []].insert(candidate.definition)
            for name in candidate.sampleNames { names[name, default: []].insert(candidate.definition) }
        }
        for (index, candidate) in candidates.enumerated() where !rejected.contains(index) {
            if families[candidate.family!, default: []].count > 1 ||
                candidate.sampleNames.contains(where: { names[$0, default: []].count > 1 }) {
                rejected.insert(index)
            }
        }
        var samples: [PoolPrometheusSampleIdentity: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() where !rejected.contains(index) {
            let labels = candidate.labels.filter { !$0.value.isEmpty }
            for name in candidate.sampleNames {
                samples[.init(name: name, labels: labels), default: []].append(index)
            }
        }
        for indices in samples.values where indices.count > 1 { rejected.formUnion(indices) }
        let accepted = candidates.enumerated().filter { !rejected.contains($0.offset) }.map(\.element)
        let grouped = Dictionary(grouping: accepted, by: { $0.family! })
        var output = ""
        for (family, metrics) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let first = metrics.first else { continue }
            let type = first.value.isDistribution ? "summary" : first.kind
            output += "# TYPE \(family) \(type)\n"
            output += metrics.flatMap { $0.lines() }.sorted().joined(separator: "\n") + "\n\n"
        }
        return PoolPrometheusExportResult(text: output, rejectedSeriesCount: rejected.count)
    }
}

private struct PoolPrometheusDefinition: Hashable {
    let name: String
    let kind: String
}

private struct PoolPrometheusSampleIdentity: Hashable {
    let name: String
    let labels: [String: String]
}

private enum PoolPrometheusValue {
    case counter(UInt64)
    case gauge(Double)
    case distribution(count: Int, sum: Double, quantiles: [(String, Double)])

    var isDistribution: Bool {
        if case .distribution = self { return true }
        return false
    }

    var isFinite: Bool {
        switch self {
        case .counter: return true
        case .gauge(let value): return value.isFinite
        case .distribution(let count, let sum, let quantiles):
            // swiftlint:disable:next empty_count -- count is a numeric sample total, not a collection.
            return count >= 0 && sum.isFinite && quantiles.allSatisfy { $0.1.isFinite }
        }
    }
}

private struct PoolPrometheusCandidate {
    let key: String
    let name: String
    let kind: String
    let labels: [String: String]
    let value: PoolPrometheusValue

    var family: String? { PrometheusTextFormat.metricName(name) }
    var definition: PoolPrometheusDefinition { .init(name: name, kind: kind) }
    var sampleNames: [String] {
        guard let family else { return [] }
        return value.isDistribution ? [family, family + "_sum", family + "_count"] : [family]
    }

    func lines() -> [String] {
        guard let family else { return [] }
        let suffix = formatLabels(labels)
        switch value {
        case .counter(let value): return ["\(family)\(suffix) \(value)"]
        case .gauge(let value): return ["\(family)\(suffix) \(PrometheusTextFormat.value(value))"]
        case .distribution(let count, let sum, let quantiles):
            var lines = ["\(family)_count\(suffix) \(count)",
                         "\(family)_sum\(suffix) \(PrometheusTextFormat.value(sum))"]
            for (quantile, value) in quantiles {
                var dimensions = labels
                dimensions["quantile"] = quantile
                lines.append("\(family)\(formatLabels(dimensions)) \(PrometheusTextFormat.value(value))")
            }
            return lines
        }
    }

    private func formatLabels(_ labels: [String: String]) -> String {
        guard !labels.isEmpty else { return "" }
        return "{" + labels.sorted(by: { $0.key < $1.key }).map {
            "\($0.key)=\"\(PrometheusTextFormat.escapeLabelValue($0.value))\""
        }.joined(separator: ",") + "}"
    }
}
