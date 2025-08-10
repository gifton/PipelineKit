import Foundation
import PipelineKitCore

/// A simple exporter that prints metrics to the console.
///
/// Useful for debugging and development.
public struct ConsoleExporter: MetricExporter {
    public enum Format: Sendable {
        case compact    // Single line per metric
        case pretty     // Multi-line with indentation
        case json       // JSON format
    }

    private let format: Format
    private let prefix: String

    public init(format: Format = .compact, prefix: String = "[METRIC]") {
        self.format = format
        self.prefix = prefix
    }

    public func export(_ metrics: [MetricSnapshot]) async throws {
        for metric in metrics {
            let output = formatMetric(metric)
            print("\(prefix) \(output)")
        }
    }

    private func formatMetric(_ metric: MetricSnapshot) -> String {
        switch format {
        case .compact:
            return formatCompact(metric)
        case .pretty:
            return formatPretty(metric)
        case .json:
            return formatJSON(metric)
        }
    }

    private func formatCompact(_ metric: MetricSnapshot) -> String {
        let tags = metric.tags.isEmpty ? "" : " " + metric.tags
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")

        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.type) \(metric.name)\(tags) = \(metric.value)\(unit)"
    }

    private func formatPretty(_ metric: MetricSnapshot) -> String {
        var lines = [
            "\(metric.type.uppercased()): \(metric.name)",
            "  Value: \(metric.value)"
        ]

        if let unit = metric.unit {
            lines.append("  Unit: \(unit)")
        }

        if !metric.tags.isEmpty {
            lines.append("  Tags:")
            for (key, value) in metric.tags.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key): \(value)")
            }
        }

        lines.append("  Time: \(metric.timestamp)")

        return lines.joined(separator: "\n")
    }

    private func formatJSON(_ metric: MetricSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(metric),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        return formatCompact(metric) // Fallback
    }
}
