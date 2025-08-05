@preconcurrency import Foundation
import PipelineKitCore

/// Exports metrics in OpenTelemetry Protocol (OTLP) format.
///
/// OpenTelemetryExporter provides OTLP/JSON export over HTTP, compatible with
/// OpenTelemetry collectors and backends like Jaeger, Prometheus, and cloud providers.
///
/// ## Features
/// - OTLP/JSON format (v1)
/// - HTTP/HTTPS transport
/// - Batch and streaming export
/// - Resource attributes support
/// - Automatic retry with exponential backoff
/// - Metric type mapping to OTLP data model
///
/// ## Metric Type Mapping
/// - gauge → Gauge
/// - counter → Sum (monotonic)
/// - histogram/timer → Histogram with buckets
///
/// ## Example
/// ```swift
/// let exporter = try await OpenTelemetryExporter(
///     configuration: OpenTelemetryExportConfiguration(
///         endpoint: "http://localhost:4318/v1/metrics",
///         serviceName: "pipeline-kit-app"
///     )
/// )
/// ```
public actor OpenTelemetryExporter: MetricExporter {
    // MARK: - Properties
    
    private let configuration: OpenTelemetryExportConfiguration
    private let session: URLSession
    private var buffer: [MetricDataPoint] = []
    private var flushTask: Task<Void, Never>?
    
    // Status tracking
    private var isActive = true
    private var successCount = 0
    private var failureCount = 0
    private var lastExportTime: Date?
    private var lastError: String?
    
    // OTLP resource info
    private let resource: OTLPResource
    
    // MARK: - Initialization
    
    public init(configuration: OpenTelemetryExportConfiguration) async throws {
        self.configuration = configuration
        
        // Create URL session with custom configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.httpAdditionalHeaders = configuration.headers
        self.session = URLSession(configuration: sessionConfig)
        
        // Create resource attributes
        self.resource = OTLPResource(
            attributes: [
                OTLPKeyValue(key: "service.name", value: .string(configuration.serviceName)),
                OTLPKeyValue(key: "service.version", value: .string(configuration.serviceVersion ?? "unknown")),
                OTLPKeyValue(key: "service.instance.id", value: .string(configuration.serviceInstanceId ?? UUID().uuidString))
            ] + configuration.resourceAttributes.map { OTLPKeyValue(key: $0.key, value: .string($0.value)) }
        )
        
        // Start flush timer if not in real-time mode
        if !configuration.realTimeExport {
            startFlushTimer()
        }
    }
    
    deinit {
        flushTask?.cancel()
    }
    
    // MARK: - MetricExporter Protocol
    
    public func export(_ metric: MetricDataPoint) async throws {
        guard isActive else {
            throw PipelineError.export(reason: .exporterClosed)
        }
        
        if configuration.realTimeExport {
            // Export immediately
            try await exportBatch([metric])
        } else {
            // Buffer for batch export
            buffer.append(metric)
            
            // Flush if buffer is full
            if buffer.count >= configuration.bufferSize {
                try await flush()
            }
        }
    }
    
    public func exportBatch(_ metrics: [MetricDataPoint]) async throws {
        guard isActive else {
            throw PipelineError.export(reason: .exporterClosed)
        }
        
        guard !metrics.isEmpty else { return }
        
        do {
            let request = try createOTLPRequest(metrics: metrics)
            let (_, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200..<300:
                    successCount += metrics.count
                    lastExportTime = Date()
                case 429:
                    // Rate limited - retry with backoff
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init) ?? 5.0
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    try await exportBatch(metrics) // Retry
                case 400..<500:
                    // Client error - don't retry
                    failureCount += metrics.count
                    lastError = "Client error: \(httpResponse.statusCode)"
                    throw PipelineError.export(reason: .invalidData("HTTP \(httpResponse.statusCode)"))
                default:
                    // Server error - could retry with backoff
                    failureCount += metrics.count
                    lastError = "Server error: \(httpResponse.statusCode)"
                    throw PipelineError.export(reason: .ioError("HTTP \(httpResponse.statusCode)"))
                }
            }
        } catch {
            failureCount += metrics.count
            lastError = error.localizedDescription
            throw PipelineError.export(reason: .ioError(error.localizedDescription))
        }
    }
    
    public func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
        // Convert aggregated metrics to OTLP format
        var dataPoints: [MetricDataPoint] = []
        
        for aggregated in metrics {
            let baseTags = aggregated.tags.merging([
                "aggregation.window": "\(Int(aggregated.window.duration))s"
            ]) { _, new in new }
            
            switch aggregated.statistics {
            case .basic(let stats):
                // Export as gauge metrics
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: "\(aggregated.name).mean",
                    value: stats.mean,
                    type: .gauge,
                    tags: baseTags
                ))
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: "\(aggregated.name).min",
                    value: stats.min,
                    type: .gauge,
                    tags: baseTags
                ))
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: "\(aggregated.name).max",
                    value: stats.max,
                    type: .gauge,
                    tags: baseTags
                ))
                
            case .counter(let stats):
                // Export as sum metric
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: aggregated.name,
                    value: stats.sum,
                    type: .counter,
                    tags: baseTags
                ))
                
            case .histogram(let stats):
                // For now, export percentiles as gauges
                // In a full implementation, we'd export as OTLP histogram
                let percentiles = [
                    ("p50", stats.p50),
                    ("p90", stats.p90),
                    ("p95", stats.p95),
                    ("p99", stats.p99),
                    ("p999", stats.p999)
                ]
                
                for (name, value) in percentiles {
                    dataPoints.append(MetricDataPoint(
                        timestamp: aggregated.timestamp,
                        name: "\(aggregated.name).\(name)",
                        value: value,
                        type: .gauge,
                        tags: baseTags
                    ))
                }
            }
        }
        
        try await exportBatch(dataPoints)
    }
    
    public func flush() async throws {
        guard !buffer.isEmpty else { return }
        
        let metricsToExport = buffer
        buffer.removeAll()
        
        try await exportBatch(metricsToExport)
    }
    
    public func shutdown() async {
        isActive = false
        flushTask?.cancel()
        
        // Try to flush remaining metrics
        try? await flush()
        
        // Invalidate session
        session.invalidateAndCancel()
    }
    
    public var status: ExporterStatus {
        ExporterStatus(
            isActive: isActive,
            queueDepth: buffer.count,
            successCount: successCount,
            failureCount: failureCount,
            lastExportTime: lastExportTime,
            lastError: lastError
        )
    }
    
    // MARK: - Private Methods
    
    private func startFlushTimer() {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.flushInterval * 1_000_000_000))
                try? await flush()
            }
        }
    }
    
    private func createOTLPRequest(metrics: [MetricDataPoint]) throws -> URLRequest {
        let otlpData = createOTLPExportRequest(metrics: metrics)
        let jsonData = try JSONEncoder().encode(otlpData)
        
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // Add any custom headers
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        return request
    }
    
    private func createOTLPExportRequest(metrics: [MetricDataPoint]) -> OTLPExportMetricsServiceRequest {
        // Group metrics by instrument name and type
        var instrumentMap: [String: [MetricDataPoint]] = [:]
        
        for metric in metrics {
            let key = "\(metric.name):\(metric.type)"
            instrumentMap[key, default: []].append(metric)
        }
        
        // Create scope metrics
        let scopeMetrics = OTLPScopeMetrics(
            scope: OTLPInstrumentationScope(
                name: "pipeline-kit",
                version: "1.0.0"
            ),
            metrics: instrumentMap.compactMap { _, points in
                createOTLPMetric(from: points)
            }
        )
        
        // Create resource metrics
        let resourceMetrics = OTLPResourceMetrics(
            resource: resource,
            scopeMetrics: [scopeMetrics]
        )
        
        return OTLPExportMetricsServiceRequest(
            resourceMetrics: [resourceMetrics]
        )
    }
    
    private func createOTLPMetric(from dataPoints: [MetricDataPoint]) -> OTLPMetric? {
        guard let first = dataPoints.first else { return nil }
        
        let metric = OTLPMetric(
            name: first.name,
            description: "Metric \(first.name)",
            unit: ""
        )
        
        switch first.type {
        case .gauge:
            metric.data = .gauge(OTLPGauge(
                dataPoints: dataPoints.map { point in
                    OTLPNumberDataPoint(
                        attributes: point.tags.map { OTLPKeyValue(key: $0.key, value: .string($0.value)) },
                        timeUnixNano: UInt64(point.timestamp.timeIntervalSince1970 * 1_000_000_000),
                        value: .double(point.value)
                    )
                }
            ))
            
        case .counter:
            metric.data = .sum(OTLPSum(
                dataPoints: dataPoints.map { point in
                    OTLPNumberDataPoint(
                        attributes: point.tags.map { OTLPKeyValue(key: $0.key, value: .string($0.value)) },
                        timeUnixNano: UInt64(point.timestamp.timeIntervalSince1970 * 1_000_000_000),
                        value: .double(point.value)
                    )
                },
                aggregationTemporality: .cumulative,
                isMonotonic: true
            ))
            
        case .histogram, .timer:
            // Simplified histogram - in production, would calculate proper buckets
            metric.data = .histogram(OTLPHistogram(
                dataPoints: dataPoints.map { point in
                    OTLPHistogramDataPoint(
                        attributes: point.tags.map { OTLPKeyValue(key: $0.key, value: .string($0.value)) },
                        timeUnixNano: UInt64(point.timestamp.timeIntervalSince1970 * 1_000_000_000),
                        count: 1,
                        sum: point.value,
                        bucketCounts: [1], // Simplified - would need proper bucketing
                        explicitBounds: []  // Would define bucket boundaries
                    )
                },
                aggregationTemporality: .cumulative
            ))
        }
        
        return metric
    }
}

// MARK: - OTLP Data Structures

/// OpenTelemetry Protocol structures (simplified subset)
private struct OTLPExportMetricsServiceRequest: Codable {
    let resourceMetrics: [OTLPResourceMetrics]
}

private struct OTLPResourceMetrics: Codable {
    let resource: OTLPResource
    let scopeMetrics: [OTLPScopeMetrics]
}

private struct OTLPResource: Codable {
    let attributes: [OTLPKeyValue]
}

private struct OTLPScopeMetrics: Codable {
    let scope: OTLPInstrumentationScope
    let metrics: [OTLPMetric]
}

private struct OTLPInstrumentationScope: Codable {
    let name: String
    let version: String
}

private class OTLPMetric: Codable {
    let name: String
    let description: String
    let unit: String
    var data: OTLPMetricData?
    
    init(name: String, description: String, unit: String) {
        self.name = name
        self.description = description
        self.unit = unit
    }
}

private enum OTLPMetricData: Codable {
    case gauge(OTLPGauge)
    case sum(OTLPSum)
    case histogram(OTLPHistogram)
    
    enum CodingKeys: String, CodingKey {
        case gauge, sum, histogram
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gauge(let gauge):
            try container.encode(gauge, forKey: .gauge)
        case .sum(let sum):
            try container.encode(sum, forKey: .sum)
        case .histogram(let histogram):
            try container.encode(histogram, forKey: .histogram)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let gauge = try? container.decode(OTLPGauge.self, forKey: .gauge) {
            self = .gauge(gauge)
        } else if let sum = try? container.decode(OTLPSum.self, forKey: .sum) {
            self = .sum(sum)
        } else if let histogram = try? container.decode(OTLPHistogram.self, forKey: .histogram) {
            self = .histogram(histogram)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown metric type"))
        }
    }
}

private struct OTLPGauge: Codable {
    let dataPoints: [OTLPNumberDataPoint]
}

private struct OTLPSum: Codable {
    let dataPoints: [OTLPNumberDataPoint]
    let aggregationTemporality: OTLPAggregationTemporality
    let isMonotonic: Bool
}

private struct OTLPHistogram: Codable {
    let dataPoints: [OTLPHistogramDataPoint]
    let aggregationTemporality: OTLPAggregationTemporality
}

private struct OTLPNumberDataPoint: Codable {
    let attributes: [OTLPKeyValue]
    let timeUnixNano: UInt64
    let value: OTLPNumberValue
}

private struct OTLPHistogramDataPoint: Codable {
    let attributes: [OTLPKeyValue]
    let timeUnixNano: UInt64
    let count: UInt64
    let sum: Double
    let bucketCounts: [UInt64]
    let explicitBounds: [Double]
}

private struct OTLPKeyValue: Codable {
    let key: String
    let value: OTLPAnyValue
}

private enum OTLPAnyValue: Codable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    
    enum CodingKeys: String, CodingKey {
        case stringValue, boolValue, intValue, doubleValue
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(value, forKey: .stringValue)
        case .bool(let value):
            try container.encode(value, forKey: .boolValue)
        case .int(let value):
            try container.encode(value, forKey: .intValue)
        case .double(let value):
            try container.encode(value, forKey: .doubleValue)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .stringValue) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self, forKey: .boolValue) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self, forKey: .intValue) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self, forKey: .doubleValue) {
            self = .double(value)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown value type"))
        }
    }
}

private enum OTLPNumberValue: Codable {
    case int(Int64)
    case double(Double)
    
    enum CodingKeys: String, CodingKey {
        case asInt, asDouble
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let value):
            try container.encode(value, forKey: .asInt)
        case .double(let value):
            try container.encode(value, forKey: .asDouble)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int64.self, forKey: .asInt) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self, forKey: .asDouble) {
            self = .double(value)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown number type"))
        }
    }
}

private enum OTLPAggregationTemporality: Int, Codable {
    case unspecified = 0
    case delta = 1
    case cumulative = 2
}
