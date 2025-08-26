import Foundation
#if canImport(Network)
import Network
#endif

/// Production-ready StatsD exporter with Swift 6 concurrency support.
///
/// Features:
/// - Swift 6 strict concurrency compliant
/// - Transport abstraction for flexible backend support
/// - Error handling and reporting
/// - Metric batching for efficiency
/// - Automatic reconnection on failure
public actor StatsDExporter: MetricRecorder {
    /// Configuration for the exporter.
    public struct Configuration: Sendable {
        public let host: String
        public let port: Int
        public let prefix: String?
        public let globalTags: [String: String]
        public let maxBatchSize: Int
        public let flushInterval: TimeInterval
        
        // Sampling configuration
        public let sampleRate: Double  // Global default (0.0-1.0)
        public let sampleRatesByType: [String: Double]  // Per-type overrides
        public let criticalPatterns: [String]  // Never sample these patterns
        
        // Aggregation configuration
        public let aggregation: AggregationConfiguration
        
        // Transport configuration
        public let useTransport: Bool  // Enable new transport layer
        public let transportTimeout: TimeInterval
        
        public init(
            host: String = "localhost",
            port: Int = 8125,
            prefix: String? = nil,
            globalTags: [String: String] = [:],
            maxBatchSize: Int = 20,
            flushInterval: TimeInterval = 0.1,
            sampleRate: Double = 1.0,
            sampleRatesByType: [String: Double] = [:],
            criticalPatterns: [String] = ["error", "timeout", "failure", "fatal", "panic"],
            aggregation: AggregationConfiguration = AggregationConfiguration(),
            useTransport: Bool = false,  // Default to legacy for backward compatibility
            transportTimeout: TimeInterval = 1.0
        ) {
            self.host = host
            self.port = port
            self.prefix = prefix
            self.globalTags = globalTags
            self.maxBatchSize = maxBatchSize
            self.flushInterval = flushInterval
            
            // Clamp sample rate to valid range
            self.sampleRate = max(0.0, min(1.0, sampleRate))
            
            // Clamp per-type rates
            self.sampleRatesByType = sampleRatesByType.mapValues { max(0.0, min(1.0, $0)) }
            
            self.criticalPatterns = criticalPatterns
            self.aggregation = aggregation
            self.useTransport = useTransport
            self.transportTimeout = transportTimeout
        }
        
        public static let `default` = Configuration()
    }
    
    #if canImport(Network)
    /// Connection state machine (legacy)
    private enum ConnectionState {
        case disconnected
        case connecting
        case connected(NWConnection)
        case failed(Error)
    }
    #endif
    
    private let configuration: Configuration
    
    // Transport layer (new)
    private var transport: (any MetricsTransport)?
    
    #if canImport(Network)
    // Legacy connection handling
    private var connectionState = ConnectionState.disconnected
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    #endif
    
    // Batching support
    private var buffer: [String] = []
    private var flushTask: Task<Void, Never>?
    
    // Aggregation support
    private let aggregator: MetricAggregator?
    
    // Error handling
    private var errorHandler: (@Sendable (Error) -> Void)?
    
    /// Sets the error handler.
    public func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        self.errorHandler = handler
    }
    
    /// Creates a new StatsD exporter with optional transport.
    public init(configuration: Configuration = .default, transport: (any MetricsTransport)? = nil) async {
        self.configuration = configuration
        
        // Initialize aggregator if enabled
        if configuration.aggregation.enabled {
            self.aggregator = MetricAggregator(configuration: configuration.aggregation)
        } else {
            self.aggregator = nil
        }
        
        // Set up transport
        if let providedTransport = transport {
            self.transport = providedTransport
        } else if configuration.useTransport {
            // Create default UDP transport
            let udpConfig = UDPTransport.Configuration(
                host: configuration.host,
                port: configuration.port,
                timeout: configuration.transportTimeout
            )
            self.transport = try? await UDPTransport(configuration: udpConfig)
        }
    }
    
    /// Creates a new StatsD exporter (backward compatibility).
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        
        // Initialize aggregator if enabled
        if configuration.aggregation.enabled {
            self.aggregator = MetricAggregator(configuration: configuration.aggregation)
        } else {
            self.aggregator = nil
        }
        
        // No transport in sync init (use legacy path)
        self.transport = nil
    }
    
    // MARK: - Sampling Logic
    
    /// Stable hash function for deterministic sampling across program runs.
    /// Uses DJB2 algorithm - simple, fast, and good distribution.
    nonisolated private func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)  // hash * 33 + byte
        }
        return hash
    }
    
    /// Determines if a metric should be sampled and at what rate.
    nonisolated private func shouldSample(_ snapshot: MetricSnapshot) -> (sample: Bool, rate: Double) {
        // Check critical patterns first - never sample these
        let nameLower = snapshot.name.lowercased()
        for pattern in configuration.criticalPatterns {
            if nameLower.contains(pattern) {
                return (true, 1.0)  // Always keep critical metrics
            }
        }
        
        // Get effective sample rate (type-specific or global)
        let rate = configuration.sampleRatesByType[snapshot.type] ?? configuration.sampleRate
        
        // If rate is 1.0, always sample
        guard rate < 1.0 else { return (true, 1.0) }
        
        // Deterministic sampling using stable hash
        // This ensures consistent sampling across program runs
        let hash = stableHash(snapshot.name)
        let normalizedHash = Double(hash) / Double(UInt64.max)
        let shouldSample = normalizedHash < rate
        
        return (shouldSample, rate)
    }
    
    deinit {
        #if canImport(Network)
        // Clean up connection on deinit
        if case .connected(let connection) = connectionState {
            connection.cancel()
        }
        #endif
        flushTask?.cancel()
    }
    
    /// Records a metric snapshot.
    public func record(_ snapshot: MetricSnapshot) async {
        // Check if we should sample this metric
        let (shouldSample, rate) = self.shouldSample(snapshot)
        guard shouldSample else { return }  // Drop if not sampled
        
        // If aggregation is enabled, aggregate instead of sending immediately
        if let aggregator = aggregator {
            // Note: Counter scaling happens inside aggregator for pre-scaled values
            let success = await aggregator.aggregate(snapshot, sampleRate: rate)
            if !success {
                // Buffer full, force flush and retry
                await flushAggregatedMetrics()
                _ = await aggregator.aggregate(snapshot, sampleRate: rate)
            }
        } else {
            // Original path: scale and send immediately
            var adjustedSnapshot = snapshot
            if snapshot.type == "counter" && rate < 1.0 {
                // Use default value of 1.0 if value is nil (standard counter increment)
                let effectiveValue = snapshot.value ?? 1.0
                adjustedSnapshot = MetricSnapshot(
                    name: snapshot.name,
                    type: snapshot.type,
                    value: effectiveValue / rate,  // Scale up to compensate for sampling
                    timestamp: snapshot.timestamp,
                    tags: snapshot.tags,
                    unit: snapshot.unit
                )
            }
            
            let line = formatMetric(adjustedSnapshot, sampleRate: rate)
            await bufferMetric(line)
        }
    }
    
    /// Formats a metric in StatsD format (pure function - can be nonisolated).
    nonisolated private func formatMetric(_ snapshot: MetricSnapshot, sampleRate: Double = 1.0) -> String {
        var name = sanitizeMetricName(snapshot.name)
        if let prefix = configuration.prefix {
            name = "\(prefix).\(name)"
        }
        
        let value = snapshot.value ?? 1.0
        let typeChar = statsdType(for: snapshot.type)
        
        // Build base metric line
        var line = "\(name):\(value)|\(typeChar)"
        
        // Add sample rate if sampling is active
        if sampleRate < 1.0 {
            line += "|@\(sampleRate)"
        }
        
        // Add tags (DogStatsD format)
        let allTags = mergeTags(configuration.globalTags, snapshot.tags)
        if !allTags.isEmpty {
            let tagString = allTags
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            line += "|#\(tagString)"
        }
        
        return line
    }
    
    /// Sanitizes metric names for StatsD compatibility.
    nonisolated private func sanitizeMetricName(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "@", with: "_")
            .replacingOccurrences(of: "#", with: "_")
    }
    
    /// Gets the StatsD type character.
    nonisolated private func statsdType(for type: String) -> String {
        #if DEBUG
        let validTypes = ["counter", "gauge", "timer", "histogram"]
        if !validTypes.contains(type) {
            print("[MetricsExporter] Warning: Unknown metric type '\(type)', defaulting to gauge")
        }
        #endif
        
        switch type {
        case "counter": return "c"
        case "gauge": return "g"
        case "timer": return "ms"
        case "histogram": return "h"
        default: return "g"
        }
    }
    
    /// Merges two tag dictionaries.
    nonisolated private func mergeTags(_ base: [String: String], _ additional: [String: String]) -> [String: String] {
        var merged = base
        for (key, value) in additional {
            merged[key] = value
        }
        return merged
    }
    
    /// Buffers a metric line for batched sending.
    private func bufferMetric(_ line: String) async {
        buffer.append(line)
        
        if buffer.count >= configuration.maxBatchSize {
            await flush()
        } else if flushTask == nil {
            // Start flush timer
            flushTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(configuration.flushInterval))
                await self.flush()
            }
        }
    }
    
    /// Flushes buffered metrics.
    private func flush() async {
        guard !buffer.isEmpty else { return }
        
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        flushTask?.cancel()
        flushTask = nil
        
        // Use transport if available, otherwise legacy
        if transport != nil {
            await sendViaTransport(batch)
        } else {
            let data = batch.joined(separator: "\n")
            await sendLegacy(data)
        }
    }
    
    /// Sends metrics via transport layer.
    private func sendViaTransport(_ lines: [String]) async {
        guard let transport = transport else { return }
        
        do {
            // Convert each line to Data
            let packets = lines.compactMap { $0.data(using: .utf8) }
            
            if packets.count == 1 {
                try await transport.send(packets[0])
            } else if !packets.isEmpty {
                try await transport.sendBatch(packets)
            }
        } catch {
            reportError(error)
        }
    }
    
    /// Sends data via UDP (legacy).
    private func sendLegacy(_ data: String) async {
        #if canImport(Network)
        do {
            try await ensureConnection()
            
            guard let messageData = data.data(using: .utf8) else {
                reportError(MetricsError.invalidData("Failed to encode metric data"))
                return
            }
            
            if case .connected(let connection) = connectionState {
                connection.send(content: messageData, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        Task { [weak self] in
                            await self?.handleSendError(error)
                        }
                    }
                })
            }
        } catch {
            reportError(error)
        }
        #endif
    }
    
    #if canImport(Network)
    /// Ensures connection is established.
    private func ensureConnection() async throws {
        switch connectionState {
        case .connected:
            return // Already connected
            
        case .connecting:
            // Wait for connection to complete
            await withCheckedContinuation { continuation in
                self.connectionContinuation = continuation
            }
            
        case .disconnected, .failed:
            try await connect()
        }
    }
    
    /// Establishes a new connection.
    private func connect() async throws {
        connectionState = .connecting
        
        let host = NWEndpoint.Host(configuration.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(configuration.port))
        let connection = NWConnection(host: host, port: port, using: .udp)
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleConnectionStateChange(state, connection: connection)
                }
            }
            
            connection.start(queue: .global())
            continuation.resume()
        }
    }
    
    /// Handles connection state changes.
    private func handleConnectionStateChange(_ state: NWConnection.State, connection: NWConnection) async {
        switch state {
        case .ready:
            connectionState = .connected(connection)
            connectionContinuation?.resume()
            connectionContinuation = nil
            
        case .failed(let error):
            connectionState = .failed(error)
            connectionContinuation?.resume()
            connectionContinuation = nil
            reportError(MetricsError.connectionFailed(error))
            
        case .cancelled:
            connectionState = .disconnected
            connectionContinuation?.resume()
            connectionContinuation = nil
            
        default:
            break // Ignore other states
        }
    }
    
    /// Handles send errors.
    private func handleSendError(_ error: NWError) async {
        connectionState = .disconnected
        reportError(MetricsError.sendFailed(error.localizedDescription))
    }
    #endif
    
    /// Reports an error through the configured handler.
    private func reportError(_ error: Error) {
        errorHandler?(error)
        #if DEBUG
        print("[MetricsExporter] Error: \(error)")
        #endif
    }
    
    /// Batch sends multiple metrics.
    public func recordBatch(_ snapshots: [MetricSnapshot]) async {
        for snapshot in snapshots {
            await record(snapshot)
        }
    }
    
    /// Forces a flush of buffered metrics.
    public func forceFlush() async {
        // Flush aggregated metrics first if enabled
        if aggregator != nil {
            await flushAggregatedMetrics()
        }
        await flush()
    }
    
    /// Flushes aggregated metrics from the aggregator.
    private func flushAggregatedMetrics() async {
        guard let aggregator = aggregator else { return }
        
        let aggregatedMetrics = await aggregator.forceFlush()
        for (snapshot, sampleRate) in aggregatedMetrics {
            let line = formatMetric(snapshot, sampleRate: sampleRate)
            await bufferMetric(line)
        }
    }
}

// MARK: - Test Support

public extension StatsDExporter {
    /// Creates an exporter with a mock transport for testing.
    static func withMockTransport(
        configuration: Configuration = .default,
        mockConfig: MockTransport.Configuration = MockTransport.Configuration()
    ) async -> (StatsDExporter, MockTransport)? {
        do {
            let mockTransport = try await MockTransport(configuration: mockConfig)
            let exporter = await StatsDExporter(configuration: configuration, transport: mockTransport)
            return (exporter, mockTransport)
        } catch {
            print("Failed to create mock transport: \(error)")
            return nil
        }
    }
}

// MARK: - Convenience Methods

public extension StatsDExporter {
    /// Records a counter metric.
    func counter(_ name: String, value: Double = 1.0, tags: [String: String] = [:]) async {
        await record(MetricSnapshot.counter(name, value: value, tags: tags))
    }
    
    /// Records a gauge metric.
    func gauge(_ name: String, value: Double, tags: [String: String] = [:]) async {
        await record(MetricSnapshot.gauge(name, value: value, tags: tags))
    }
    
    /// Records a timer metric.
    func timer(_ name: String, duration: TimeInterval, tags: [String: String] = [:]) async {
        await record(MetricSnapshot.timer(name, duration: duration, tags: tags))
    }
    
    /// Times a block of code using ContinuousClock for accuracy.
    func time<T: Sendable>(_ name: String, tags: [String: String] = [:], block: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let result = try await block()
        let elapsed = ContinuousClock.now - start
        let duration = Double(elapsed.components.seconds) +
                       Double(elapsed.components.attoseconds) / 1e18
        await timer(name, duration: duration, tags: tags)
        return result
    }
}

// MARK: - Error Types

/// Errors that can occur in metrics export.
public enum MetricsError: Error, LocalizedError {
    case connectionFailed(Error)
    case sendFailed(String)
    case invalidData(String)
    case configurationError(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let error):
            return "Failed to connect to StatsD: \(error.localizedDescription)"
        case .sendFailed(let message):
            return "Failed to send metrics: \(message)"
        case .invalidData(let message):
            return "Invalid metric data: \(message)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }
}
