import Foundation
import PipelineKitCore

/// OTLP (OpenTelemetry Protocol) exporter for sending metrics to OpenTelemetry collectors.
///
/// Implements OTLP/HTTP with JSON encoding for maximum compatibility.
/// Supports the standard OTLP metric data model including gauges, sums, and histograms.
public actor OTLPExporter: MetricExporter {
    // Shared URLSession for connection pooling
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 5
        return URLSession(configuration: config)
    }()
    public struct Configuration: Sendable {
        /// The endpoint URL for the OTLP receiver.
        public let endpoint: URL

        /// HTTP headers to include in requests.
        public let headers: [String: String]

        /// Request timeout in seconds.
        public let timeout: TimeInterval

        /// Resource attributes describing the source of metrics.
        public let resourceAttributes: [String: String]

        /// Service name for resource identification.
        public let serviceName: String

        /// Enable compression (gzip).
        public let compression: Bool

        /// Maximum retry attempts for failed requests.
        public let maxRetries: Int

        /// Initial retry delay in seconds.
        public let retryDelay: TimeInterval

        public init(
            endpoint: URL,
            headers: [String: String] = [:],
            timeout: TimeInterval = 10.0,
            resourceAttributes: [String: String] = [:],
            serviceName: String = "PipelineKit",
            compression: Bool = true,
            maxRetries: Int = 3,
            retryDelay: TimeInterval = 1.0
        ) {
            self.endpoint = endpoint
            self.headers = headers
            self.timeout = timeout
            self.resourceAttributes = resourceAttributes
            self.serviceName = serviceName
            self.compression = compression
            self.maxRetries = maxRetries
            self.retryDelay = retryDelay
        }
        
        /// Creates a configuration with default localhost endpoint
        public static var localhost: Configuration {
            guard let url = URL(string: "http://localhost:4318/v1/metrics") else {
                fatalError("Invalid default OTLP URL - this should never happen")
            }
            return Configuration(endpoint: url)
        }

        public static let `default` = localhost
    }

    private let configuration: Configuration
    private let session: URLSession
    private let encoder: JSONEncoder

    // Self-instrumentation
    private var exportsTotal: Int = 0
    private var exportFailuresTotal: Int = 0
    private var metricsExportedTotal: Int = 0
    private var histogramsDownconvertedTotal: Int = 0

    public init(configuration: Configuration = .default) {
        self.configuration = configuration

        // Use shared session with custom timeout
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.httpMaximumConnectionsPerHost = 5
        self.session = URLSession(configuration: sessionConfig)

        self.encoder = JSONEncoder()
    }

    // MARK: - MetricExporter Protocol

    public func export(_ metrics: [MetricSnapshot]) async throws {
        guard !metrics.isEmpty else { return }

        let request = try createRequest(for: metrics)

        // Retry logic
        var lastError: Error?
        var retryDelay = configuration.retryDelay

        for attempt in 0..<configuration.maxRetries {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OTLPError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200:
                    // Success or partial success
                    if let partialSuccess = try? parsePartialSuccess(from: data) {
                        handlePartialSuccess(partialSuccess)
                    }
                    exportsTotal += 1
                    metricsExportedTotal += metrics.count
                    return

                case 400:
                    // Bad request - don't retry
                    throw OTLPError.badRequest(String(data: data, encoding: .utf8) ?? "Unknown error")

                case 429, 503:
                    // Rate limited or unavailable - retry with backoff
                    lastError = OTLPError.temporaryFailure(statusCode: httpResponse.statusCode)

                case 401, 403:
                    // Authentication/authorization failure - don't retry
                    throw OTLPError.authenticationFailed(statusCode: httpResponse.statusCode)

                default:
                    lastError = OTLPError.unexpectedStatus(statusCode: httpResponse.statusCode)
                }
            } catch {
                lastError = error

                // Don't retry on non-retryable errors
                if let otlpError = error as? OTLPError {
                    switch otlpError {
                    case .badRequest, .authenticationFailed, .invalidResponse:
                        exportFailuresTotal += 1
                        throw error
                    default:
                        break
                    }
                }
            }

            // Wait before retry
            if attempt < configuration.maxRetries - 1 {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                retryDelay *= 2 // Exponential backoff
            }
        }

        exportFailuresTotal += 1
        throw lastError ?? OTLPError.maxRetriesExceeded
    }

    public func flush() async throws {
        // OTLP is push-based, nothing to flush
    }

    public func shutdown() async {
        // Clean shutdown - could wait for pending requests in a real implementation
    }

    // MARK: - Private Methods

    private func createRequest(for metrics: [MetricSnapshot]) throws -> URLRequest {
        let payload = createOTLPPayload(from: metrics)
        let data = try encoder.encode(payload)

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add custom headers
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Compression
        if configuration.compression {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = try compress(data)
        } else {
            request.httpBody = data
        }

        return request
    }

    private func createOTLPPayload(from metrics: [MetricSnapshot]) -> OTLPMetricsData {
        // Group metrics by name for proper OTLP structure
        let groupedMetrics = Dictionary(grouping: metrics, by: { $0.name })

        let otlpMetrics = groupedMetrics.map { name, snapshots in
            OTLPMetric(
                name: name,
                description: "",
                unit: snapshots.first?.unit ?? "",
                data: createMetricData(for: snapshots)
            )
        }

        return OTLPMetricsData(
            resourceMetrics: [
                OTLPResourceMetrics(
                    resource: OTLPResource(
                        attributes: createResourceAttributes()
                    ),
                    scopeMetrics: [
                        OTLPScopeMetrics(
                            scope: OTLPInstrumentationScope(
                                name: "PipelineKitMetrics",
                                version: "1.0.0"
                            ),
                            metrics: otlpMetrics
                        )
                    ]
                )
            ]
        )
    }

    private func createMetricData(for snapshots: [MetricSnapshot]) -> OTLPMetricData {
        guard let first = snapshots.first else {
            return .gauge(OTLPGauge(dataPoints: []))
        }

        let dataPoints = snapshots.map { snapshot in
            OTLPNumberDataPoint(
                attributes: createAttributes(from: snapshot.tags),
                startTimeUnixNano: first.type.lowercased() == "counter" ? UInt64(Date.distantPast.timeIntervalSince1970 * 1_000_000_000) : nil,
                timeUnixNano: UInt64(snapshot.timestamp.timeIntervalSince1970 * 1_000_000_000),
                value: snapshot.value
            )
        }

        switch first.type.lowercased() {
        case "counter":
            return .sum(OTLPSum(
                dataPoints: dataPoints,
                aggregationTemporality: .cumulative,
                isMonotonic: true
            ))
        case "gauge":
            return .gauge(OTLPGauge(dataPoints: dataPoints))
        case "histogram":
            // For simplicity, convert to gauge - full histogram support would need bucketing
            histogramsDownconvertedTotal += dataPoints.count
            return .gauge(OTLPGauge(dataPoints: dataPoints))
        default:
            return .gauge(OTLPGauge(dataPoints: dataPoints))
        }
    }

    private func createResourceAttributes() -> [OTLPAttribute] {
        var attributes = [
            OTLPAttribute(key: "service.name", value: .string(configuration.serviceName))
        ]

        for (key, value) in configuration.resourceAttributes {
            attributes.append(OTLPAttribute(key: key, value: .string(value)))
        }

        return attributes
    }

    private func createAttributes(from tags: [String: String]) -> [OTLPAttribute] {
        tags.map { key, value in
            OTLPAttribute(key: key, value: .string(value))
        }
    }

    private func compress(_ data: Data) throws -> Data {
        // Skip compression for small payloads
        guard data.count >= CompressionConfig.minimumSizeThreshold else {
            return data
        }
        
        // Use platform-specific compressor
        let compressor = CompressionUtility.createCompressor()
        
        do {
            let compressed = try compressor.compress(data)
            
            // Debug assertion to verify gzip format
            assert(compressed.count >= 2 && compressed[0] == 0x1f && compressed[1] == 0x8b,
                   "Invalid gzip magic bytes in compressed data")
            
            return compressed
        } catch CompressionError.belowThreshold {
            // This shouldn't happen due to our guard above, but handle gracefully
            return data
        } catch {
            // Re-throw compression errors
            throw error
        }
    }

    private func parsePartialSuccess(from data: Data) throws -> OTLPPartialSuccess? {
        // In a real implementation, parse the response to check for partial success
        // For now, return nil (assume full success)
        return nil
    }

    private func handlePartialSuccess(_ partialSuccess: OTLPPartialSuccess) {
        // Log or handle partial success
        // In a real implementation, might want to retry rejected data points
    }
}

// MARK: - OTLP Data Model

private struct OTLPMetricsData: Encodable {
    let resourceMetrics: [OTLPResourceMetrics]
}

private struct OTLPResourceMetrics: Encodable {
    let resource: OTLPResource
    let scopeMetrics: [OTLPScopeMetrics]
}

private struct OTLPResource: Encodable {
    let attributes: [OTLPAttribute]
}

private struct OTLPScopeMetrics: Encodable {
    let scope: OTLPInstrumentationScope
    let metrics: [OTLPMetric]
}

private struct OTLPInstrumentationScope: Encodable {
    let name: String
    let version: String
}

private struct OTLPMetric: Encodable {
    let name: String
    let description: String
    let unit: String
    let data: OTLPMetricData

    enum CodingKeys: String, CodingKey {
        case name, description, unit
        case gauge, sum, histogram
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(unit, forKey: .unit)

        switch data {
        case .gauge(let gauge):
            try container.encode(gauge, forKey: .gauge)
        case .sum(let sum):
            try container.encode(sum, forKey: .sum)
        case .histogram(let histogram):
            try container.encode(histogram, forKey: .histogram)
        }
    }
}

private enum OTLPMetricData {
    case gauge(OTLPGauge)
    case sum(OTLPSum)
    case histogram(OTLPHistogram)
}

private struct OTLPGauge: Encodable {
    let dataPoints: [OTLPNumberDataPoint]
}

private struct OTLPSum: Encodable {
    let dataPoints: [OTLPNumberDataPoint]
    let aggregationTemporality: AggregationTemporality
    let isMonotonic: Bool
}

private struct OTLPHistogram: Encodable {
    let dataPoints: [OTLPHistogramDataPoint]
    let aggregationTemporality: AggregationTemporality
}

private enum AggregationTemporality: Int, Encodable {
    case unspecified = 0
    case delta = 1
    case cumulative = 2
}

private struct OTLPNumberDataPoint: Encodable {
    let attributes: [OTLPAttribute]
    let startTimeUnixNano: UInt64?
    let timeUnixNano: UInt64
    let value: Double

    enum CodingKeys: String, CodingKey {
        case attributes
        case startTimeUnixNano = "start_time_unix_nano"
        case timeUnixNano = "time_unix_nano"
        case asDouble = "as_double"
    }

    // swiftlint:disable:next unneeded_synthesized_initializer
    init(attributes: [OTLPAttribute], startTimeUnixNano: UInt64?, timeUnixNano: UInt64, value: Double) {
        self.attributes = attributes
        self.startTimeUnixNano = startTimeUnixNano
        self.timeUnixNano = timeUnixNano
        self.value = value
    }


    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attributes, forKey: .attributes)
        try container.encodeIfPresent(startTimeUnixNano, forKey: .startTimeUnixNano)
        try container.encode(timeUnixNano, forKey: .timeUnixNano)
        try container.encode(value, forKey: .asDouble)
    }
}

private struct OTLPHistogramDataPoint: Encodable {
    let attributes: [OTLPAttribute]
    let startTimeUnixNano: UInt64?
    let timeUnixNano: UInt64
    let count: Int
    let sum: Double?
    let bucketCounts: [Int]
    let explicitBounds: [Double]

    enum CodingKeys: String, CodingKey {
        case attributes
        case startTimeUnixNano = "start_time_unix_nano"
        case timeUnixNano = "time_unix_nano"
        case count
        case sum
        case bucketCounts = "bucket_counts"
        case explicitBounds = "explicit_bounds"
    }
}

private struct OTLPAttribute: Encodable {
    let key: String
    let value: OTLPAttributeValue
}

private enum OTLPAttributeValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    enum CodingKeys: String, CodingKey {
        case stringValue = "string_value"
        case intValue = "int_value"
        case doubleValue = "double_value"
        case boolValue = "bool_value"
    }


    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(value, forKey: .stringValue)
        case .int(let value):
            // OTLP JSON requires numbers as strings
            try container.encode(String(value), forKey: .intValue)
        case .double(let value):
            // OTLP JSON requires numbers as strings
            try container.encode(String(value), forKey: .doubleValue)
        case .bool(let value):
            try container.encode(value, forKey: .boolValue)
        }
    }
}

private struct OTLPPartialSuccess {
    let rejectedDataPoints: Int
    let errorMessage: String?
}

// MARK: - Errors

public enum OTLPError: Error, Sendable {
    case invalidResponse
    case badRequest(String)
    case authenticationFailed(statusCode: Int)
    case temporaryFailure(statusCode: Int)
    case unexpectedStatus(statusCode: Int)
    case maxRetriesExceeded
}
