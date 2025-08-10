import Foundation
import PipelineKitCore

/// Exports metrics in Prometheus text exposition format.
///
/// PrometheusExporter converts metrics to the Prometheus text format,
/// suitable for scraping by a Prometheus server.
///
/// Note: Prometheus uses a pull model, so this exporter stores metrics
/// in memory to be scraped via an HTTP endpoint.
public actor PrometheusExporter: MetricExporter {
    public struct Configuration: Sendable {
        /// Global labels to add to all metrics.
        public let globalLabels: [String: String]

        /// Metric name prefix.
        public let prefix: String

        /// Whether to include timestamps.
        public let includeTimestamp: Bool

        /// Whether to include help text.
        public let includeHelp: Bool

        public init(
            globalLabels: [String: String] = [:],
            prefix: String = "",
            includeTimestamp: Bool = false,
            includeHelp: Bool = true
        ) {
            self.globalLabels = globalLabels
            self.prefix = prefix
            self.includeTimestamp = includeTimestamp
            self.includeHelp = includeHelp
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var currentMetrics: [String: MetricSnapshot] = [:]  // Key by name+tags

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - MetricExporter Protocol

    /// Store metrics for Prometheus scraping.
    ///
    /// Since Prometheus uses a pull model, this stores metrics in memory
    /// rather than pushing them to a server.
    public func export(_ metrics: [MetricSnapshot]) async throws {
        for metric in metrics {
            let key = metricKey(for: metric)
            currentMetrics[key] = metric
        }
    }

    /// No-op for Prometheus (pull-based model).
    public func flush() async throws {
        // Prometheus is pull-based, nothing to flush
    }

    /// Clear stored metrics on shutdown.
    public func shutdown() async {
        currentMetrics.removeAll()
    }

    // MARK: - Prometheus-Specific Methods

    /// Get current metrics in Prometheus text format for scraping.
    ///
    /// - Returns: Prometheus-formatted text
    public func scrape() -> String {
        let metrics = Array(currentMetrics.values)
        return formatMetrics(metrics)
    }

    /// Format metrics to Prometheus text exposition format.
    ///
    /// - Parameter metrics: Metrics to format
    /// - Returns: Prometheus-formatted text
    private func formatMetrics(_ metrics: [MetricSnapshot]) -> String {
        var lines: [String] = []

        // Group metrics by name for proper formatting
        let grouped = Dictionary(grouping: metrics) { $0.name }

        for (name, snapshots) in grouped.sorted(by: { $0.key < $1.key }) {
            let metricName = sanitizeName(configuration.prefix + name)

            // Add help text if configured
            if configuration.includeHelp, let first = snapshots.first {
                lines.append("# HELP \(metricName) \(helpText(for: first.type))")
                lines.append("# TYPE \(metricName) \(prometheusType(for: first.type))")
            }

            // Export each metric instance
            for snapshot in snapshots {
                let mergedTags = snapshot.tags.merging(configuration.globalLabels) { _, new in new }
                let labels = formatLabels(mergedTags)

                var line = "\(metricName)\(labels) \(snapshot.value)"

                if configuration.includeTimestamp {
                    let timestamp = Int64(snapshot.timestamp.timeIntervalSince1970 * 1000)
                    line += " \(timestamp)"
                }

                lines.append(line)
            }

            // Add blank line between metrics
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Generate a unique key for metric deduplication.
    private func metricKey(for metric: MetricSnapshot) -> String {
        let sortedTags = metric.tags
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        return "\(metric.name){\(sortedTags)}"
    }

    // MARK: - Private Methods

    private func sanitizeName(_ name: String) -> String {
        // Prometheus naming rules: [a-zA-Z_:][a-zA-Z0-9_:]*
        name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func formatLabels(_ tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "" }

        let pairs = tags
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\"\(escapeValue($0.value))\"" }
            .joined(separator: ",")

        return "{\(pairs)}"
    }

    private func escapeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func prometheusType(for metricType: String) -> String {
        switch metricType.lowercased() {
        case "counter":
            return "counter"
        case "gauge":
            return "gauge"
        case "histogram", "timer":
            return "histogram"
        default:
            return "untyped"
        }
    }

    private func helpText(for metricType: String) -> String {
        switch metricType.lowercased() {
        case "counter":
            return "Counter metric"
        case "gauge":
            return "Gauge metric"
        case "histogram":
            return "Histogram metric"
        case "timer":
            return "Timer metric"
        default:
            return "Metric"
        }
    }
}
