import Foundation
#if canImport(Network)
import Network
#endif

/// Exports metrics in Prometheus text exposition format.
///
/// PrometheusExporter provides an HTTP endpoint that Prometheus can scrape.
/// It converts PipelineKit metric types to Prometheus types and formats
/// them according to the Prometheus text format specification.
///
/// ## Metric Type Mapping
/// - gauge → gauge
/// - counter → counter  
/// - histogram/timer → histogram with buckets
///
/// ## Features
/// - HTTP server for scraping endpoint
/// - Automatic metric type conversion
/// - Label support from tags
/// - Metric name sanitization
/// - Optional timestamps
public actor PrometheusExporter: MetricExporter {
    // MARK: - Properties
    
    private let configuration: PrometheusExportConfiguration
    private var metrics: [String: PrometheusMetric] = [:]
    private var httpServer: HTTPServer?
    
    // Status tracking
    private var isActive = true
    private var successCount = 0
    private var failureCount = 0
    private var lastExportTime: Date?
    private var lastError: String?
    
    // Histogram buckets (in seconds for timers, raw values for histograms)
    private let defaultBuckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
    
    // MARK: - Initialization
    
    public init(configuration: PrometheusExportConfiguration) async throws {
        self.configuration = configuration
        
        // Start HTTP server
        httpServer = HTTPServer(
            port: configuration.port,
            host: configuration.host,
            handler: { [weak self] request in
                await self?.handleHTTPRequest(request) ?? HTTPResponse.notFound()
            }
        )
        
        try await httpServer?.start()
    }
    
    // MARK: - MetricExporter Protocol
    
    public func export(_ metric: MetricDataPoint) async throws {
        guard isActive else {
            throw ExportError.shutdownInProgress
        }
        
        let prometheusName = sanitizeMetricName(configuration.prefix + metric.name)
        let labels = metric.tags.merging(configuration.globalLabels) { _, new in new }
        
        switch metric.type {
        case .gauge:
            metrics[prometheusName] = PrometheusMetric(
                name: prometheusName,
                type: .gauge,
                help: "Gauge metric \(metric.name)",
                samples: [PrometheusMetric.Sample(
                    labels: labels,
                    value: metric.value,
                    timestamp: configuration.includeTimestamp ? metric.timestamp : nil
                )]
            )
            
        case .counter:
            if var existing = metrics[prometheusName] {
                // Update counter value
                if let existingSample = existing.samples.first(where: { $0.labels == labels }) {
                    // Counter should only increase
                    if metric.value >= existingSample.value {
                        existing.samples.removeAll { $0.labels == labels }
                        existing.samples.append(PrometheusMetric.Sample(
                            labels: labels,
                            value: metric.value,
                            timestamp: configuration.includeTimestamp ? metric.timestamp : nil
                        ))
                        metrics[prometheusName] = existing
                    }
                } else {
                    existing.samples.append(PrometheusMetric.Sample(
                        labels: labels,
                        value: metric.value,
                        timestamp: configuration.includeTimestamp ? metric.timestamp : nil
                    ))
                    metrics[prometheusName] = existing
                }
            } else {
                metrics[prometheusName] = PrometheusMetric(
                    name: prometheusName,
                    type: .counter,
                    help: "Counter metric \(metric.name)",
                    samples: [PrometheusMetric.Sample(
                        labels: labels,
                        value: metric.value,
                        timestamp: configuration.includeTimestamp ? metric.timestamp : nil
                    )]
                )
            }
            
        case .histogram, .timer:
            // For histogram/timer, we store individual observations
            // and calculate buckets on demand
            let histogramName = prometheusName
            if var existing = metrics[histogramName] {
                existing.observations.append(metric.value)
                metrics[histogramName] = existing
            } else {
                var histogram = PrometheusMetric(
                    name: histogramName,
                    type: .histogram,
                    help: "Histogram metric \(metric.name)",
                    samples: []
                )
                histogram.observations = [metric.value]
                metrics[histogramName] = histogram
            }
        }
        
        successCount += 1
        lastExportTime = Date()
    }
    
    public func exportBatch(_ metrics: [MetricDataPoint]) async throws {
        for metric in metrics {
            try await export(metric)
        }
    }
    
    public func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
        // Convert aggregated metrics to Prometheus format
        for aggregated in metrics {
            let prometheusName = sanitizeMetricName(configuration.prefix + aggregated.name)
            let labels = aggregated.tags.merging(configuration.globalLabels) { _, new in new }
                .merging(["window": "\(Int(aggregated.window.duration))s"]) { _, new in new }
            
            switch aggregated.statistics {
            case .basic(let stats):
                // Export as gauge with multiple series for each statistic
                self.metrics["\(prometheusName)_mean"] = PrometheusMetric(
                    name: "\(prometheusName)_mean",
                    type: .gauge,
                    help: "Mean value of \(aggregated.name)",
                    samples: [PrometheusMetric.Sample(
                        labels: labels,
                        value: stats.mean,
                        timestamp: configuration.includeTimestamp ? aggregated.timestamp : nil
                    )]
                )
                
                self.metrics["\(prometheusName)_min"] = PrometheusMetric(
                    name: "\(prometheusName)_min",
                    type: .gauge,
                    help: "Minimum value of \(aggregated.name)",
                    samples: [PrometheusMetric.Sample(
                        labels: labels,
                        value: stats.min,
                        timestamp: configuration.includeTimestamp ? aggregated.timestamp : nil
                    )]
                )
                
                self.metrics["\(prometheusName)_max"] = PrometheusMetric(
                    name: "\(prometheusName)_max",
                    type: .gauge,
                    help: "Maximum value of \(aggregated.name)",
                    samples: [PrometheusMetric.Sample(
                        labels: labels,
                        value: stats.max,
                        timestamp: configuration.includeTimestamp ? aggregated.timestamp : nil
                    )]
                )
                
            case .counter(let stats):
                self.metrics["\(prometheusName)_rate"] = PrometheusMetric(
                    name: "\(prometheusName)_rate",
                    type: .gauge,
                    help: "Rate of \(aggregated.name) per second",
                    samples: [PrometheusMetric.Sample(
                        labels: labels,
                        value: stats.rate,
                        timestamp: configuration.includeTimestamp ? aggregated.timestamp : nil
                    )]
                )
                
            case .histogram(let stats):
                // Export percentiles as gauges
                let percentiles = [
                    ("p50", stats.p50),
                    ("p90", stats.p90),
                    ("p95", stats.p95),
                    ("p99", stats.p99),
                    ("p999", stats.p999)
                ]
                
                for (percentile, value) in percentiles {
                    self.metrics["\(prometheusName)_\(percentile)"] = PrometheusMetric(
                        name: "\(prometheusName)_\(percentile)",
                        type: .gauge,
                        help: "\(percentile) of \(aggregated.name)",
                        samples: [PrometheusMetric.Sample(
                            labels: labels,
                            value: value,
                            timestamp: configuration.includeTimestamp ? aggregated.timestamp : nil
                        )]
                    )
                }
            }
        }
    }
    
    public func flush() async throws {
        // No-op for Prometheus - metrics are served on demand
    }
    
    public func shutdown() async {
        isActive = false
        await httpServer?.stop()
        metrics.removeAll()
    }
    
    public var status: ExporterStatus {
        ExporterStatus(
            isActive: isActive,
            queueDepth: 0, // No queue for Prometheus
            successCount: successCount,
            failureCount: failureCount,
            lastExportTime: lastExportTime,
            lastError: lastError
        )
    }
    
    // MARK: - HTTP Handler
    
    private func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == configuration.metricsPath else {
            return HTTPResponse.notFound()
        }
        
        do {
            let output = try formatMetrics()
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/plain; version=0.0.4"],
                body: output
            )
        } catch {
            lastError = error.localizedDescription
            failureCount += 1
            return HTTPResponse.error(500, "Internal Server Error")
        }
    }
    
    // MARK: - Prometheus Format
    
    private func formatMetrics() throws -> String {
        var output = ""
        
        // Sort metrics by name for consistent output
        let sortedMetrics = metrics.sorted { $0.key < $1.key }
        
        for (_, metric) in sortedMetrics {
            // Write help and type
            output += "# HELP \(metric.name) \(metric.help)\n"
            output += "# TYPE \(metric.name) \(metric.type.rawValue)\n"
            
            switch metric.type {
            case .gauge, .counter:
                // Simple metrics
                for sample in metric.samples {
                    output += formatSample(metric.name, labels: sample.labels, value: sample.value, timestamp: sample.timestamp)
                }
                
            case .histogram:
                // Calculate histogram buckets
                let observations = metric.observations
                let buckets = calculateBuckets(observations)
                
                // Output buckets
                for (bound, count) in buckets {
                    let bucketLabels = metric.samples.first?.labels ?? [:]
                    let labels = bucketLabels.merging(["le": formatDouble(bound)]) { _, new in new }
                    output += formatSample("\(metric.name)_bucket", labels: labels, value: Double(count))
                }
                
                // Output +Inf bucket
                let infLabels = (metric.samples.first?.labels ?? [:]).merging(["le": "+Inf"]) { _, new in new }
                output += formatSample("\(metric.name)_bucket", labels: infLabels, value: Double(observations.count))
                
                // Output sum and count
                let sum = observations.reduce(0, +)
                output += formatSample("\(metric.name)_sum", labels: metric.samples.first?.labels ?? [:], value: sum)
                output += formatSample("\(metric.name)_count", labels: metric.samples.first?.labels ?? [:], value: Double(observations.count))
            }
            
            output += "\n"
        }
        
        return output
    }
    
    private func formatSample(_ name: String, labels: [String: String], value: Double, timestamp: Date? = nil) -> String {
        var line = name
        
        // Add labels if any
        if !labels.isEmpty {
            let labelPairs = labels
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\"\(escapeLabelValue($0.value))\"" }
                .joined(separator: ",")
            line += "{\(labelPairs)}"
        }
        
        line += " \(formatDouble(value))"
        
        // Add timestamp if configured
        if let timestamp = timestamp, configuration.includeTimestamp {
            line += " \(Int(timestamp.timeIntervalSince1970 * 1000))"
        }
        
        line += "\n"
        
        return line
    }
    
    private func calculateBuckets(_ observations: [Double]) -> [(Double, Int)] {
        var buckets: [(Double, Int)] = []
        
        for bound in defaultBuckets {
            let count = observations.filter { $0 <= bound }.count
            buckets.append((bound, count))
        }
        
        return buckets
    }
    
    private func sanitizeMetricName(_ name: String) -> String {
        // Prometheus metric names must match [a-zA-Z_:][a-zA-Z0-9_:]*
        let sanitized = name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        
        // Ensure it starts with a letter or underscore
        if let first = sanitized.first, !first.isLetter && first != "_" {
            return "_" + sanitized
        }
        
        return sanitized
    }
    
    private func escapeLabelValue(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    
    private func formatDouble(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        } else if value.isInfinite {
            return value > 0 ? "+Inf" : "-Inf"
        } else {
            return String(format: "%.6g", value)
        }
    }
}

// MARK: - Supporting Types

/// Prometheus metric representation.
private struct PrometheusMetric {
    let name: String
    let type: MetricType
    let help: String
    var samples: [Sample]
    var observations: [Double] = [] // For histograms
    
    struct Sample: Equatable {
        let labels: [String: String]
        let value: Double
        let timestamp: Date?
        
        static func == (lhs: Sample, rhs: Sample) -> Bool {
            lhs.labels == rhs.labels
        }
    }
    
    enum MetricType: String {
        case gauge = "gauge"
        case counter = "counter"
        case histogram = "histogram"
    }
}

// MARK: - Simple HTTP Server

/// Minimal HTTP server for Prometheus endpoint.
private actor HTTPServer {
    private let port: Int
    private let host: String
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    
    init(port: Int, host: String, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.host = host
        self.handler = handler
    }
    
    func start() async throws {
        #if canImport(Network)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleConnection(connection)
            }
        }
        
        listener?.start(queue: .global())
        #else
        throw ExportError.destinationUnavailable("Network framework not available")
        #endif
    }
    
    func stop() async {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #endif
    }
    
    #if canImport(Network)
    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            guard let data = data, error == nil else {
                connection.cancel()
                return
            }
            
            Task {
                if let request = HTTPRequest.parse(from: data) {
                    let response = await self.handler(request)
                    let responseData = response.format()
                    
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    connection.cancel()
                }
            }
        }
    }
    #endif
}

/// Minimal HTTP request.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    
    static func parse(from data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        
        return HTTPRequest(
            method: requestLine[0],
            path: requestLine[1],
            headers: [:]
        )
    }
}

/// Minimal HTTP response.
private struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: String
    
    func format() -> Data {
        var response = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "\r\n"
        response += body
        
        return Data(response.utf8)
    }
    
    static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, headers: [:], body: "Not Found")
    }
    
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: message)
    }
    
    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}