import PipelineKitCore

/// A StatsD snapshot and the number of stored series omitted from it.
public struct PoolStatsDExportResult: Sendable {
    /// Each element is one datagram. Keep a negative gauge's reset/update pair together.
    public let datagrams: [String]
    /// Number of source series omitted because of invalid data or conflicting wire identities.
    public let rejectedSeriesCount: Int
}

public extension MetricsSnapshot {
    /// Exports a stateless snapshot as absolute StatsD gauges with DogStatsD tags.
    /// Send each array element as one datagram: a negative gauge contains both its
    /// zero reset and signed update. Repeated snapshots retain absolute values.
    func statsdFormat() -> [String] { statsdFormatWithDiagnostics().datagrams }

    /// Exports cumulative counters and distribution statistics as gauges.
    /// Histograms use `_count`, `_sum`, `_mean`, `_min`, `_max`, `_p50`, `_p95`,
    /// and `_p99`; summaries use `_count`, `_sum`, `_p50`, `_p90`, `_p95`, `_p99`,
    /// and `_p999`. Invalid wire names/labels and conflicting generated names
    /// reject the whole source series, which increments rejectedSeriesCount once.
    func statsdFormatWithDiagnostics() -> PoolStatsDExportResult {
        var candidates: [PoolStatsDCandidate] = []
        for (key, value) in counters {
            candidates.append(.init(name: metricNames[key] ?? key, kind: "counter", tags: labels[key] ?? [:],
                                    samples: [("", .unsigned(value))]))
        }
        for (key, value) in gauges {
            candidates.append(.init(name: metricNames[key] ?? key, kind: "gauge", tags: labels[key] ?? [:],
                                    samples: [("", .floating(value))]))
        }
        for (key, value) in histograms {
            candidates.append(.init(name: metricNames[key] ?? key, kind: "histogram", tags: labels[key] ?? [:], samples: [
                ("_count", .count(value.count)), ("_sum", .floating(value.sum)), ("_mean", .floating(value.mean)),
                ("_min", .floating(value.min)), ("_max", .floating(value.max)), ("_p50", .floating(value.p50)),
                ("_p95", .floating(value.p95)), ("_p99", .floating(value.p99))
            ]))
        }
        for (key, value) in summaries {
            candidates.append(.init(name: metricNames[key] ?? key, kind: "summary", tags: labels[key] ?? [:], samples: [
                ("_count", .count(value.count)), ("_sum", .floating(value.sum)), ("_p50", .floating(value.p50)),
                ("_p90", .floating(value.p90)), ("_p95", .floating(value.p95)), ("_p99", .floating(value.p99)),
                ("_p999", .floating(value.p999))
            ]))
        }

        var rejected: Set<Int> = []
        var packets: [Int: [String]] = [:]
        var owners: [String: Set<PoolStatsDDefinition>] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let encoded = candidate.packets() else {
                rejected.insert(index)
                continue
            }
            packets[index] = encoded
            for name in candidate.sampleNames {
                owners[name, default: []].insert(candidate.definition)
            }
        }
        for (index, candidate) in candidates.enumerated() where !rejected.contains(index) {
            if candidate.sampleNames.contains(where: { owners[$0, default: []].count > 1 }) {
                rejected.insert(index)
            }
        }
        var samples: [PoolStatsDSampleIdentity: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() where !rejected.contains(index) {
            for name in candidate.sampleNames {
                samples[.init(name: name, tags: candidate.tags), default: []].append(index)
            }
        }
        for indices in samples.values where indices.count > 1 { rejected.formUnion(indices) }
        let datagrams = packets.filter { !rejected.contains($0.key) }.flatMap(\.value).sorted()
        return PoolStatsDExportResult(datagrams: datagrams, rejectedSeriesCount: rejected.count)
    }
}

private struct PoolStatsDDefinition: Hashable {
    let name: String
    let kind: String
}

private struct PoolStatsDSampleIdentity: Hashable {
    let name: String
    let tags: [String: String]
}

private enum PoolStatsDValue {
    case unsigned(UInt64)
    case count(Int)
    case floating(Double)

    func packet(name: String, tags: [String: String]) -> String? {
        switch self {
        case .unsigned(let value): return StatsDTextFormat.packet(name: name, value: value, type: "g", tags: tags)
        case .count(let value):
            guard value >= 0 else { return nil }
            return StatsDTextFormat.packet(name: name, value: UInt64(value), type: "g", tags: tags)
        case .floating(let value): return StatsDTextFormat.packet(name: name, value: value, type: "g", tags: tags)
        }
    }
}

private struct PoolStatsDCandidate {
    let name: String
    let kind: String
    let tags: [String: String]
    let samples: [(suffix: String, value: PoolStatsDValue)]

    var definition: PoolStatsDDefinition { .init(name: name, kind: kind) }
    var sampleNames: [String] { samples.map { name + $0.suffix } }

    func packets() -> [String]? {
        guard !name.isEmpty, StatsDTextFormat.sanitizeMetricName(name) == name,
              StatsDTextFormat.areValidTags(tags) else { return nil }
        var packets: [String] = []
        for sample in samples {
            guard let packet = sample.value.packet(name: name + sample.suffix, tags: tags) else { return nil }
            packets.append(packet)
        }
        return packets
    }
}
