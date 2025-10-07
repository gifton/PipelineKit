//
//  PrometheusExporter.swift
//  PipelineKitObservability
//
//  Exports metrics in Prometheus text format for monitoring and observability
//

import Foundation

/// Exports metrics in Prometheus text format
///
/// This exporter converts metrics from MetricsStorage into the Prometheus
/// exposition format, enabling integration with Prometheus and Grafana.
///
/// ## Usage
/// ```swift
/// let storage = await MetricsStorage()
/// let exporter = PrometheusExporter(metricsStorage: storage)
///
/// // In your HTTP handler:
/// app.get("/metrics") { req in
///     await exporter.export()
/// }
/// ```
///
/// ## Prometheus Format
/// ```
/// # TYPE api_requests_total counter
/// api_requests_total{endpoint="/users",method="GET"} 1547
///
/// # TYPE memory_usage_bytes gauge
/// memory_usage_bytes{host="server1"} 79691776
///
/// # TYPE request_duration_milliseconds histogram
/// request_duration_milliseconds_bucket{le="10"} 25
/// request_duration_milliseconds_bucket{le="50"} 100
/// request_duration_milliseconds_bucket{le="+Inf"} 144
/// request_duration_milliseconds_sum 6000
/// request_duration_milliseconds_count 144
/// ```
///
/// - SeeAlso: [Prometheus Exposition Format](https://prometheus.io/docs/instrumenting/exposition_formats/)
public actor PrometheusExporter {
    private let metricsStorage: MetricsStorage

    /// Creates a Prometheus exporter
    ///
    /// - Parameter metricsStorage: The metrics storage to export from
    public init(metricsStorage: MetricsStorage) {
        self.metricsStorage = metricsStorage
    }

    /// Export metrics in Prometheus text format
    ///
    /// Returns all metrics from storage formatted according to the Prometheus
    /// exposition format. This output can be scraped by Prometheus servers.
    ///
    /// - Returns: Formatted metrics string ready for Prometheus scraping
    public func export() async -> String {
        let snapshots = await metricsStorage.getAll()
        var output = ""

        // Group metrics by name for proper Prometheus format
        let grouped = Dictionary(grouping: snapshots, by: { $0.name })

        for (name, metrics) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let first = metrics.first else { continue }

            // Write TYPE comment with full metric name (including suffix)
            let promType = prometheusType(from: first.type)
            let metricName = metricNameWithSuffix(name, type: first.type)
            output += "# TYPE \(metricName) \(promType)\n"

            // Write metric lines
            for metric in metrics {
                output += formatMetric(metric)
            }

            output += "\n"
        }

        return output
    }

    // MARK: - Formatting

    /// Formats a single metric according to Prometheus conventions
    private func formatMetric(_ metric: MetricSnapshot) -> String {
        let name = sanitizeName(metric.name)
        let tags = formatTags(metric.tags)
        let value = metric.value ?? 1.0 // Default to 1 for increment-only counters
        let formattedValue = formatValue(value)

        switch metric.type {
        case "counter":
            // Counters get _total suffix per Prometheus naming convention
            return "\(name)_total\(tags) \(formattedValue)\n"

        case "gauge":
            return "\(name)\(tags) \(formattedValue)\n"

        case "histogram":
            // Simplified histogram format
            // In production, you'd want actual bucket data
            return """
            \(name)_sum\(tags) \(formattedValue)
            \(name)_count\(tags) 1

            """

        case "timer":
            // Timers exported as gauges with milliseconds suffix
            return "\(name)_milliseconds\(tags) \(formattedValue)\n"

        default:
            // Unknown types exported as gauges
            return "\(name)\(tags) \(formattedValue)\n"
        }
    }

    /// Formats tags into Prometheus label format
    ///
    /// Example: {endpoint="/users",method="GET"}
    private func formatTags(_ tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "" }

        // Sort tags for consistent output
        let formatted = tags.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key)=\"\(escapeLabelValue(value))\""
        }.joined(separator: ",")

        return "{\(formatted)}"
    }

    /// Sanitizes metric names to comply with Prometheus naming rules
    ///
    /// Prometheus metric names must match [a-zA-Z_:][a-zA-Z0-9_:]*
    /// Converts dots and dashes to underscores
    private func sanitizeName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    /// Escapes special characters in label values
    ///
    /// Handles backslash, quote, and newline characters
    private func escapeLabelValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Maps internal metric types to Prometheus types
    private func prometheusType(from type: String) -> String {
        switch type {
        case "counter": return "counter"
        case "gauge": return "gauge"
        case "histogram": return "histogram"
        case "timer": return "gauge"  // Timers exported as gauges
        default: return "gauge"       // Unknown types as gauges
        }
    }

    /// Gets the metric name with appropriate suffix based on type
    private func metricNameWithSuffix(_ name: String, type: String) -> String {
        let sanitized = sanitizeName(name)
        switch type {
        case "counter":
            return "\(sanitized)_total"
        case "timer":
            return "\(sanitized)_milliseconds"
        default:
            return sanitized
        }
    }

    /// Formats a double value, removing unnecessary decimals
    private func formatValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }
}

// MARK: - Convenience Methods

public extension PrometheusExporter {
    /// Export aggregated metrics
    ///
    /// Uses MetricsStorage's aggregation to reduce data volume before export.
    /// Useful for high-frequency metrics.
    ///
    /// - Returns: Prometheus-formatted aggregated metrics
    func exportAggregated() async -> String {
        let snapshots = await metricsStorage.aggregate()
        var output = ""

        let grouped = Dictionary(grouping: snapshots, by: { $0.name })

        for (name, metrics) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let first = metrics.first else { continue }

            let promType = prometheusType(from: first.type)
            let metricName = metricNameWithSuffix(name, type: first.type)
            output += "# TYPE \(metricName) \(promType)\n"

            for metric in metrics {
                output += formatMetric(metric)
            }

            output += "\n"
        }

        return output
    }
}
