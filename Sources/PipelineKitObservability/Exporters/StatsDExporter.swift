import Foundation

/// StatsD exporter with lazy transport startup and explicit shutdown.
/// Call `forceFlush()` before `close()` to attempt delivery of buffered metrics.
public actor StatsDExporter: FlushableMetricRecorder {
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
            self.transportTimeout = transportTimeout
        }
        
        public static let `default` = Configuration()
    }
    
    private struct Startup {
        let id: UUID
        let task: Task<any MetricsTransport, any Error>
    }

    private let configuration: Configuration
    private let transportFactory: @Sendable () async throws -> any MetricsTransport
    private var transport: (any MetricsTransport)?
    private var startup: Startup?
    private var closeTask: Task<Void, Never>?
    internal private(set) var isClosed = false
    // Registration acknowledgement for the internal factory's lifecycle tests.
    internal private(set) var startupWaiterCount = 0

    private var buffer: [String] = []
    private var flushTask: Task<Void, Never>?
    private let aggregator: MetricAggregator?
    private var errorHandler: (@Sendable (any Error) -> Void)?

    /// Installs or clears error reporting before recording or explicit startup.
    public func setErrorHandler(_ handler: (@Sendable (any Error) -> Void)?) {
        errorHandler = handler
    }

    /// Creates a lazy exporter. `start()` or the first nonempty batch starts UDP.
    public init(configuration: Configuration = .default) {
        self.init(configuration: configuration, transportFactory: {
            try await UDPTransport(configuration: .init(
                host: configuration.host,
                port: configuration.port,
                timeout: configuration.transportTimeout
            ))
        })
    }

    /// Creates an exporter owning an already initialized transport, including its close.
    public init(configuration: Configuration, transport: any MetricsTransport) {
        self.configuration = configuration
        self.transportFactory = { transport }
        self.aggregator = configuration.aggregation.enabled
            ? MetricAggregator(configuration: configuration.aggregation) : nil
        self.transport = transport
    }

    internal init(
        configuration: Configuration,
        transportFactory: @escaping @Sendable () async throws -> any MetricsTransport
    ) {
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.aggregator = configuration.aggregation.enabled
            ? MetricAggregator(configuration: configuration.aggregation) : nil
    }

    deinit {
        flushTask?.cancel()
        startup?.task.cancel()
    }

    /// Validates readiness; failure is thrown and reported through the error handler.
    public func start() async throws {
        do {
            _ = try await readyTransport()
        } catch {
            reportError(error)
            throw error
        }
    }

    private func readyTransport() async throws -> any MetricsTransport {
        guard !isClosed else { throw TransportError.transportClosed }
        if let transport { return transport }
        let owned: Startup
        if let startup {
            owned = startup
        } else {
            let id = UUID()
            let factory = transportFactory
            let task = Task { () throws -> any MetricsTransport in
                do {
                    let candidate = try await factory()
                    guard !self.isClosed, self.startup?.id == id else {
                        // Only this task owns an unpublished candidate. Coverage:
                        // testCloseDuringStartupClosesLateTransport.
                        await candidate.close()
                        throw TransportError.transportClosed
                    }
                    self.transport = candidate
                    self.startup = nil
                    return candidate
                } catch {
                    if self.startup?.id == id { self.startup = nil }
                    throw error
                }
            }
            owned = Startup(id: id, task: task)
            startup = owned
        }
        startupWaiterCount += 1
        defer { startupWaiterCount -= 1 }
        do {
            let ready = try await owned.task.value
            guard !isClosed else { throw TransportError.transportClosed }
            return ready
        } catch {
            // Waiters never publish or clear generations; only their startup task does.
            if isClosed { throw TransportError.transportClosed }
            throw error
        }
    }

    /// Rejects new records, discards buffered records and joins owned shutdown work.
    /// Call `forceFlush()` first to attempt delivery. UDP has no delivery acknowledgement.
    /// A cancellation-insensitive factory or transport can delay close indefinitely.
    /// Repeated/concurrent close shares settlement (`testCloseDuringStartupClosesLateTransport`).
    public func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        isClosed = true
        buffer.removeAll()
        let pendingStartup = startup?.task
        let pendingFlush = flushTask
        let ready = transport
        startup = nil
        transport = nil
        pendingStartup?.cancel()
        pendingFlush?.cancel()
        let aggregator = aggregator
        let closing = Task {
            await ready?.close()
            _ = await pendingStartup?.result
            await pendingFlush?.value
            if let aggregator { _ = await aggregator.forceFlush() }
        }
        closeTask = closing
        await closing.value
        flushTask = nil
    }

    // MARK: - Sampling Logic
    
    /// Stable hash function for deterministic sampling across program runs.
    /// DJB2 accumulation followed by a splitmix64 finalizer: raw DJB2 of a
    /// short string (< ~13 bytes) never wraps UInt64, so its value is tiny
    /// relative to UInt64.max and `hash / UInt64.max` collapses toward 0 —
    /// which made rate-based sampling keep everything for typical metric
    /// names. The finalizer spreads the value uniformly across UInt64.
    nonisolated private func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)  // hash * 33 + byte
        }
        hash = (hash ^ (hash >> 30)) &* 0xBF58476D1CE4E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D049BB133111EB
        hash ^= hash >> 31
        return hash
    }
    
    /// Determines if a metric should be sampled and at what rate.
    nonisolated private func shouldSample(_ snapshot: MetricSnapshot) -> (sample: Bool, rate: Double) {
        // Check critical patterns first - never sample these
        let nameLower = snapshot.name.lowercased()
        for pattern in configuration.criticalPatterns where nameLower.contains(pattern) {
            return (true, 1.0)  // Always keep critical metrics
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
    
    /// Records a metric snapshot.
    public func record(_ snapshot: MetricSnapshot) async {
        guard !isClosed else {
            reportError(TransportError.transportClosed)
            return
        }
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
        guard !isClosed else {
            reportError(TransportError.transportClosed)
            return
        }
        buffer.append(line)
        if buffer.count >= configuration.maxBatchSize {
            await flushBuffer()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func scheduleFlushIfNeeded() {
        guard !isClosed, !buffer.isEmpty, flushTask == nil else { return }
        let interval = configuration.flushInterval
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
                try Task.checkCancellation()
            } catch { return }
            await self?.flushFromTimer()
        }
    }

    private func flushFromTimer() async {
        await flushBuffer()
        flushTask = nil
        scheduleFlushIfNeeded()
    }

    /// Each invocation retains its nonempty batch across readiness and send.
    private func flushBuffer() async {
        guard !isClosed, !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        // Keep the timer's task handle until it settles, so close can join an
        // in-flight timer flush as well as cancel a sleeping timer.
        do {
            let ready = try await readyTransport()
            let packets = batch.map { Data($0.utf8) }
            if packets.count == 1 {
                try await ready.send(packets[0])
            } else {
                try await ready.sendBatch(packets)
            }
        } catch {
            reportError(error)
        }
    }

    /// Reports an error through the configured handler.
    private func reportError(_ error: any Error) {
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
    public func flush() async {
        await forceFlush()
    }

    /// Forces a flush of buffered metrics.
    public func forceFlush() async {
        guard !isClosed else { return }
        // Flush aggregated metrics first if enabled
        if aggregator != nil {
            await flushAggregatedMetrics()
        }
        await flushBuffer()
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
            let exporter = StatsDExporter(configuration: configuration, transport: mockTransport)
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
public enum MetricsError: Error, LocalizedError, Sendable {
    case connectionFailed(any Error)
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
