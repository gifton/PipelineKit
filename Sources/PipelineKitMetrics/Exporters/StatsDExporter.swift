import Foundation
import PipelineKitCore
#if canImport(Network)
import Network
#endif

/// StatsD exporter for sending metrics to StatsD-compatible servers.
///
/// Supports both vanilla StatsD and DogStatsD (with tags) formats.
/// Uses UDP for fire-and-forget metric delivery with automatic batching.
public actor StatsDExporter: MetricExporter {
    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// StatsD server hostname.
        public let host: String

        /// StatsD server port.
        public let port: Int

        /// Optional prefix for all metric names.
        public let prefix: String?

        /// Global tags to append to all metrics (DogStatsD only).
        public let globalTags: [String: String]

        /// Sample rate for metrics (0.0 to 1.0).
        public let sampleRate: Double

        /// Maximum UDP packet size in bytes.
        public let maxPacketSize: Int

        /// How often to flush buffered metrics.
        public let flushInterval: TimeInterval

        /// StatsD format variant.
        public let format: Format

        public enum Format: Sendable {
            case vanilla        // Original StatsD (no tags)
            case dogStatsD      // DataDog StatsD (with tags)
        }

        public init(
            host: String = "localhost",
            port: Int = 8125,
            prefix: String? = nil,
            globalTags: [String: String] = [:],
            sampleRate: Double = 1.0,
            maxPacketSize: Int = 1432,  // Safe for internet MTU
            flushInterval: TimeInterval = 1.0,
            format: Format = .dogStatsD
        ) {
            self.host = host
            self.port = port
            self.prefix = prefix
            self.globalTags = globalTags
            self.sampleRate = min(1.0, max(0.0, sampleRate))
            self.maxPacketSize = maxPacketSize
            self.flushInterval = flushInterval
            self.format = format
        }

        public static let `default` = Configuration()
    }

    // MARK: - Properties

    private let configuration: Configuration
    private var buffer: String = ""
    private var bufferSize: Int = 0
    private var flushTask: Task<Void, Never>?

    #if canImport(Network)
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "statsd.exporter.queue")
    private var connectionState: ConnectionState = .notStarted
    #endif

    private enum ConnectionState {
        case notStarted
        case connecting
        case ready
        case failed
    }

    // Self-instrumentation
    private var packetsTotal: Int = 0
    private var metricsTotal: Int = 0
    private var droppedMetricsTotal: Int = 0
    private var networkErrorsTotal: Int = 0

    // MARK: - Initialization

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        // Lazy initialization - connection will be created on first use
        Task {
            await startFlushTimer()
        }
    }

    deinit {
        flushTask?.cancel()
        #if canImport(Network)
        connection?.cancel()
        #endif
    }

    // MARK: - MetricExporter Protocol

    public func export(_ metrics: [MetricSnapshot]) async throws {
        guard !metrics.isEmpty else { return }

        // Ensure connection is ready (lazy initialization)
        await ensureConnection()

        for metric in metrics where shouldSample(metric) {
            // Apply sampling per metric type
            if let formatted = formatMetric(metric) {
                await appendToBuffer(formatted)
                metricsTotal += 1
            }
        }
    }

    private func shouldSample(_ metric: MetricSnapshot) -> Bool {
        guard configuration.sampleRate < 1.0 else { return true }

        // For counters and vanilla format, always send with sample rate annotation
        // For other types in DogStatsD, apply client-side sampling
        if configuration.format == .vanilla || metric.type.lowercased() == "counter" {
            return true  // Send all, let server scale
        } else {
            return Double.random(in: 0..<1) < configuration.sampleRate
        }
    }

    public func flush() async throws {
        await flushBuffer()
    }

    public func shutdown() async {
        flushTask?.cancel()
        await flushBuffer()
        #if canImport(Network)
        connection?.cancel()
        #endif
    }

    // MARK: - Format Generation

    private func formatMetric(_ metric: MetricSnapshot) -> String? {
        // Check for invalid values
        guard metric.value.isFinite else {
            droppedMetricsTotal += 1
            return nil  // Drop NaN or Inf values
        }
        // Build metric name with optional prefix
        let metricName = configuration.prefix.map { "\($0).\(metric.name)" } ?? metric.name

        // Map metric type to StatsD type code
        let typeCode: String
        switch metric.type.lowercased() {
        case "counter":
            typeCode = "c"
        case "gauge":
            typeCode = "g"
        case "histogram":
            typeCode = "h"
        case "timer", "timing":
            typeCode = "ms"
        default:
            typeCode = "g"  // Default to gauge
        }

        // Format value (handle special cases)
        let valueStr: String
        if typeCode == "ms" && metric.unit == "seconds" {
            // Convert seconds to milliseconds for timer metrics, with rounding
            valueStr = String(Int(round(metric.value * 1000)))
        } else {
            // Improved number formatting to preserve precision
            valueStr = formatNumber(metric.value)
        }

        // Build base metric string
        var result = "\(escapeMetricName(metricName)):\(valueStr)|\(typeCode)"

        // Add sample rate for counters and vanilla format
        if configuration.sampleRate < 1.0 {
            let shouldAnnotate = configuration.format == .vanilla || metric.type.lowercased() == "counter"
            if shouldAnnotate {
                result += "|@\(configuration.sampleRate)"
            }
        }

        // Add tags (DogStatsD format only)
        if configuration.format == .dogStatsD {
            let tags = mergeTags(metric.tags, with: configuration.globalTags)
            if !tags.isEmpty {
                let tagString = tags
                    .sorted(by: { $0.key < $1.key })
                    .map { "\(escapeTagKey($0.key)):\(escapeTagValue($0.value))" }
                    .joined(separator: ",")
                result += "|#\(tagString)"
            }
        }

        return result
    }

    // Character sets for escaping
    private let metricNameReserved = CharacterSet(charactersIn: ":|@#\n\r ")
    private let tagReserved = CharacterSet(charactersIn: ":,|=\n\r ")

    private func sanitize(_ string: String, reserved: CharacterSet) -> String {
        String(string.unicodeScalars.map { reserved.contains($0) ? "_" : Character($0) })
    }

    private func escapeMetricName(_ name: String) -> String {
        sanitize(name, reserved: metricNameReserved)
    }

    private func escapeTagKey(_ key: String) -> String {
        sanitize(key, reserved: tagReserved)
    }

    private func escapeTagValue(_ value: String) -> String {
        sanitize(value, reserved: tagReserved)
    }

    private func mergeTags(_ metricTags: [String: String], with globalTags: [String: String]) -> [String: String] {
        var merged = globalTags
        for (key, value) in metricTags {
            merged[key] = value  // Metric tags override global tags
        }
        return merged
    }

    // MARK: - Buffering

    private func appendToBuffer(_ metric: String) async {
        let metricSize = metric.utf8.count + 1  // +1 for newline

        // Handle oversized single metric
        if metricSize >= configuration.maxPacketSize {
            // Send directly, bypassing buffer
            await sendPacket(metric)
            return
        }

        // Check if adding this metric would exceed packet size
        if bufferSize + metricSize > configuration.maxPacketSize {
            await flushBuffer()
        }

        // Add metric to buffer
        if !buffer.isEmpty {
            buffer += "\n"
            bufferSize += 1
        }
        buffer += metric
        bufferSize += metric.utf8.count

        // Flush if we're at the limit
        if bufferSize >= configuration.maxPacketSize {
            await flushBuffer()
        }
    }

    private func flushBuffer() async {
        guard !buffer.isEmpty else { return }

        let packet = buffer
        buffer = ""
        bufferSize = 0

        await sendPacket(packet)
    }

    // MARK: - Private Helpers

    private func formatNumber(_ value: Double) -> String {
        // Handle special cases
        if value == 0 { return "0" }
        if value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e9 {
            // Integer value - no decimal point needed
            return String(Int(value))
        }

        // For very small or very large numbers, use appropriate precision
        let absValue = abs(value)
        if absValue < 1e-6 || absValue >= 1e9 {
            // Use scientific notation for extreme values
            return String(format: "%.6e", value)
        } else if absValue < 0.001 {
            // Small numbers need more decimal places
            return String(format: "%.9f", value).trimmingTrailingZeros()
        } else if absValue < 1 {
            // Normal small numbers
            return String(format: "%.6f", value).trimmingTrailingZeros()
        } else {
            // Normal numbers
            return String(format: "%.3f", value).trimmingTrailingZeros()
        }
    }

    // MARK: - Network

    private func ensureConnection() async {
        #if canImport(Network)
        switch connectionState {
        case .ready:
            return  // Already connected
        case .connecting:
            // Wait for connection to complete
            var attempts = 0
            while connectionState == .connecting && attempts < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                attempts += 1
            }
        case .notStarted, .failed:
            await setupConnection()
        }
        #endif
    }

    private func setupConnection() async {
        #if canImport(Network)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(configuration.port))
        )

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        connection = NWConnection(to: endpoint, using: params)

        connectionState = .connecting

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task {
                await self.handleConnectionStateChange(state)
            }
        }

        connection?.start(queue: queue)
        #endif
    }

    private func sendPacket(_ packet: String) async {
        #if canImport(Network)
        guard let connection = connection else {
            droppedMetricsTotal += packet.components(separatedBy: "\n").count
            return
        }

        guard let data = packet.data(using: .utf8) else {
            droppedMetricsTotal += packet.components(separatedBy: "\n").count
            return
        }

        let metricCount = packet.components(separatedBy: "\n").count

        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                Task {
                    if let error = error {
                        await self.handleNetworkError(error)
                        await self.incrementDroppedMetrics(metricCount)
                    } else {
                        await self.incrementPacketCount()
                    }
                }
                continuation.resume()
            })
        }
        #else
        // Fallback for platforms without Network framework
        // In production, you might use BSD sockets here
        droppedMetricsTotal += packet.components(separatedBy: "\n").count
        #endif
    }

    private func handleConnectionStateChange(_ state: NWConnection.State) async {
        #if canImport(Network)
        switch state {
        case .ready:
            connectionState = .ready
        case .failed(let error):
            connectionState = .failed
            await handleNetworkError(error)
            // Schedule reconnection without recursion
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
                if connectionState == .failed {
                    connectionState = .notStarted
                    // Next export() call will trigger reconnection
                }
            }
        case .preparing:
            connectionState = .connecting
        default:
            break
        }
        #endif
    }
    
    private func handleNetworkError(_ error: Error) async {
        networkErrorsTotal += 1
        // For UDP, we just log and continue - it's fire-and-forget
        // In production, you might want to log this error
    }

    private func incrementPacketCount() async {
        packetsTotal += 1
    }

    private func incrementDroppedMetrics(_ count: Int) async {
        droppedMetricsTotal += count
    }

    // MARK: - Timer

    private func startFlushTimer() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                try? await Task.sleep(nanoseconds: UInt64(self.configuration.flushInterval * 1_000_000_000))
                await self.ensureConnection()  // Ensure connection before flushing
                await self.flushBuffer()
            }
        }
    }

    // MARK: - Statistics

    public func getStats() async -> StatsDStats {
        StatsDStats(
            packetsTotal: packetsTotal,
            metricsTotal: metricsTotal,
            droppedMetricsTotal: droppedMetricsTotal,
            networkErrorsTotal: networkErrorsTotal,
            currentBufferSize: bufferSize
        )
    }
}

// MARK: - Statistics (moved outside actor)

public struct StatsDStats: Sendable {
    public let packetsTotal: Int
    public let metricsTotal: Int
    public let droppedMetricsTotal: Int
    public let networkErrorsTotal: Int
    public let currentBufferSize: Int
}

// MARK: - String Extension

private extension String {
    func trimmingTrailingZeros() -> String {
        // Only trim if there's a decimal point
        guard contains(".") else { return self }

        var result = self

        // Remove trailing zeros
        while result.hasSuffix("0") && result.contains(".") {
            result.removeLast()
        }

        // Remove trailing decimal point if all decimals were zeros
        if result.hasSuffix(".") {
            result.removeLast()
        }

        return result.isEmpty ? "0" : result  // swiftlint:disable:this colon
    }
}
