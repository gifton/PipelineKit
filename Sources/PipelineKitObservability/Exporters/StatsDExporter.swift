import Foundation
import PipelineKitCore

/// StatsD exporter with lazy transport startup and explicit shutdown.
/// Call `forceFlush()` before `close()` to attempt delivery of buffered metrics.
public actor StatsDExporter: FlushableMetricRecorder {
    private struct OperationToken: Hashable, Sendable {
        let exporterID: UUID
        let id: UUID
    }

    private enum OperationContext {
        @TaskLocal static var owners: Set<OperationToken> = []
    }

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
            _ = NumericDuration.nanoseconds(flushInterval)
            precondition(maxBatchSize > 0, "StatsD batch capacity must be positive")
            precondition(sampleRate.isFinite && sampleRatesByType.values.allSatisfy(\.isFinite),
                         "StatsD sample rates must be finite")
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

    private let operationID = UUID()
    private var activeOperations: Set<UUID> = []
    private var aggregationWireIdentities: [MetricSeriesIdentity: MetricSeriesIdentity] = [:]
    private let configuration: Configuration
    private let transportFactory: @Sendable () async throws -> any MetricsTransport
    private var transport: (any MetricsTransport)?
    private var startup: Startup?
    private var closeTask: Task<Void, Never>?
    internal private(set) var isClosed = false
    // Registration acknowledgement for the internal factory's lifecycle tests.
    internal private(set) var startupWaiterCount = 0

    private var buffer: [String] = []
    private enum FlushKind { case batch, aggregation }
    private var timerGenerations: [FlushKind: UUID] = [:]
    internal private(set) var timerTasks: [UUID: Task<Void, Never>] = [:]
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var aggregator: MetricAggregator?
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
        self.init(configuration: configuration, transport: transport,
                  sleep: { try await Task.sleep(nanoseconds: NumericDuration.nanoseconds($0)) })
    }

    internal init(configuration: Configuration, transport: any MetricsTransport,
                  sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.sleep = sleep
        self.configuration = configuration
        self.transportFactory = { transport }
        self.aggregator = configuration.aggregation.enabled
            ? MetricAggregator(configuration: configuration.aggregation) : nil
        self.transport = transport
    }

    internal init(
        configuration: Configuration,
        transportFactory: @escaping @Sendable () async throws -> any MetricsTransport,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: NumericDuration.nanoseconds($0))
        }
    ) {
        self.sleep = sleep
        self.configuration = configuration
        self.transportFactory = transportFactory
        self.aggregator = configuration.aggregation.enabled
            ? MetricAggregator(configuration: configuration.aggregation) : nil
    }

    deinit {
        for task in timerTasks.values { task.cancel() }
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
            let inherited = OperationContext.owners
            let task = Task { () throws -> any MetricsTransport in
                let token = beginOperation()
                defer { endOperation(token) }
                return try await OperationContext.$owners.withValue(inherited.union([token])) {
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
    /// Reentrant close from an owned startup, send, or close callback invalidates
    /// immediately but does not await its own task; an external close joins it.
    public func close() async {
        let isReentrant = OperationContext.owners.contains {
            $0.exporterID == operationID && activeOperations.contains($0.id)
        }
        if let closeTask {
            if !isReentrant { await closeTask.value }
            return
        }
        isClosed = true
        buffer.removeAll()
        let pendingStartup = startup?.task
        let pendingTimers = Array(timerTasks.values)
        let ready = transport
        startup = nil
        transport = nil
        pendingStartup?.cancel()
        for task in pendingTimers { task.cancel() }
        timerGenerations.removeAll()
        aggregator = nil
        aggregationWireIdentities.removeAll()
        let token = beginOperation()
        let owners = OperationContext.owners.union([token])
        let closing = Task {
            defer { endOperation(token) }
            await OperationContext.$owners.withValue(owners) {
                await ready?.close()
                _ = await pendingStartup?.result
                for task in pendingTimers { await task.value }
            }
        }
        closeTask = closing
        if !isReentrant {
            await closing.value
            timerTasks.removeAll()
        }
    }

    // MARK: - Sampling Logic
    
    /// Name-based DJB2 hashing with splitmix64 finalization.
    /// Stable short-name decisions are covered by `testDeterministicSampling`.
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
        guard !snapshot.name.isEmpty,
              let value = snapshot.value ?? (snapshot.type == "counter" ? 1 : nil), value.isFinite else {
            reportError(MetricsError.invalidData("StatsD requires a nonempty name and finite value; only counters may omit values"))
            return
        }
        guard snapshot.type != "timer" || snapshot.unit == nil || snapshot.unit == "ms" else {
            reportError(MetricsError.invalidData("StatsD timers require milliseconds"))
            return
        }
        let tags = mergeTags(configuration.globalTags, snapshot.tags)
        guard StatsDTextFormat.areValidTags(tags) else {
            reportError(MetricsError.invalidData("Tags contain unsupported StatsD delimiters or an empty key"))
            return
        }
        // Check if we should sample this metric
        let (shouldSample, rate) = self.shouldSample(snapshot)
        guard shouldSample else { return }  // Drop if not sampled
        
        if snapshot.type == "counter" && !((snapshot.value ?? 1) / rate).isFinite {
            reportError(MetricsError.invalidData("Counter sampling compensation overflowed"))
            return
        }
        if aggregator != nil {
            // Explicit and inherited tags that encode the same series share one
            // gauge update order (testAggregationUsesEffectiveGlobalTagsForLatestGauge).
            let effectiveSnapshot = MetricSnapshot(name: snapshot.name, type: snapshot.type,
                value: snapshot.value, timestamp: snapshot.timestamp, tags: tags, unit: snapshot.unit)
            let rawIdentity = MetricSeriesIdentity(name: snapshot.name, type: snapshot.type,
                                                   unit: snapshot.unit, tags: tags)
            let wireIdentity = MetricSeriesIdentity(name: wireName(snapshot.name), type: statsdType(for: snapshot.type),
                                                    unit: nil, tags: tags)
            if let existing = aggregationWireIdentities[wireIdentity], existing != rawIdentity {
                reportError(MetricsError.invalidData("Conflicting StatsD wire definition in aggregation window"))
                return
            }
            do {
                if try aggregator?.aggregate(effectiveSnapshot, sampleRate: rate) == false {
                    drainAggregatedMetrics()
                    _ = try aggregator?.aggregate(effectiveSnapshot, sampleRate: rate)
                    aggregationWireIdentities[wireIdentity] = rawIdentity
                    scheduleAggregationFlushIfNeeded()
                    await flushBuffer()
                } else {
                    aggregationWireIdentities[wireIdentity] = rawIdentity
                    scheduleAggregationFlushIfNeeded()
                }
            } catch { reportError(error) }
        } else {
            // The receiver applies @rate compensation to the retained raw amount.
            guard let packet = formatMetric(snapshot, sampleRate: rate) else {
                reportError(MetricsError.invalidData("Metric cannot be encoded as a StatsD packet"))
                return
            }
            await bufferMetric(packet)
        }
    }

    nonisolated private func formatMetric(_ snapshot: MetricSnapshot, sampleRate: Double = 1.0) -> String? {
        StatsDTextFormat.packet(name: wireName(snapshot.name), value: snapshot.value ?? 1,
            type: statsdType(for: snapshot.type), sampleRate: sampleRate,
            tags: mergeTags(configuration.globalTags, snapshot.tags))
    }

    nonisolated private func wireName(_ name: String) -> String {
        let name = StatsDTextFormat.sanitizeMetricName(name)
        if let prefix = configuration.prefix { return StatsDTextFormat.sanitizeMetricName(prefix) + "." + name }
        return name
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
        guard !buffer.isEmpty else { return }
        scheduleTimer(.batch, interval: configuration.flushInterval)
    }

    private func scheduleAggregationFlushIfNeeded() {
        guard aggregator?.isEmpty == false else { return }
        let configuration = configuration.aggregation
        let jitter = Double.random(in: -configuration.flushJitter...configuration.flushJitter)
        scheduleTimer(.aggregation, interval: configuration.flushDelay(jitter: jitter))
    }

    private func scheduleTimer(_ kind: FlushKind, interval: TimeInterval) {
        guard !isClosed, timerGenerations[kind] == nil else { return }
        let id = UUID()
        timerGenerations[kind] = id
        let sleep = sleep
        timerTasks[id] = Task { [weak self] in
            do {
                try await sleep(interval)
                try Task.checkCancellation()
                await self?.flushFromTimer(kind, generation: id)
            } catch { }
            await self?.finishTimer(id)
        }
    }

    private func finishTimer(_ id: UUID) {
        timerTasks.removeValue(forKey: id)
    }

    private func cancelTimer(_ kind: FlushKind) {
        if let id = timerGenerations.removeValue(forKey: kind) {
            timerTasks[id]?.cancel()
        }
    }

    private func flushFromTimer(_ kind: FlushKind, generation: UUID) async {
        guard !isClosed, timerGenerations[kind] == generation else { return }
        timerGenerations.removeValue(forKey: kind)
        if kind == .aggregation { drainAggregatedMetrics() }
        await flushBuffer()
    }

    /// Each invocation retains its nonempty batch across readiness and send.
    private func flushBuffer() async {
        guard !isClosed, !buffer.isEmpty else { return }
        cancelTimer(.batch)
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        // Timer task entries remain owned until their send or cancellation settles.
        let token = beginOperation()
        defer { endOperation(token) }
        do {
            try await OperationContext.$owners.withValue(OperationContext.owners.union([token])) {
                let ready = try await readyTransport()
                let packets = batch.map { Data($0.utf8) }
                if packets.count == 1 {
                    try await ready.send(packets[0])
                } else {
                    try await ready.sendBatch(packets)
                }
            }
        } catch {
            reportError(error)
        }
    }

    private func beginOperation() -> OperationToken {
        let token = OperationToken(exporterID: operationID, id: UUID())
        activeOperations.insert(token.id)
        return token
    }

    private func endOperation(_ token: OperationToken) {
        activeOperations.remove(token.id)
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

    /// Attempts delivery of buffered metrics. This does not join sends already
    /// owned by concurrent record calls; quiesce producers before shutdown.
    public func forceFlush() async {
        guard !isClosed else { return }
        drainAggregatedMetrics()
        await flushBuffer()
    }

    private func drainAggregatedMetrics() {
        cancelTimer(.aggregation)
        guard let metrics = aggregator?.flush() else { return }
        aggregationWireIdentities.removeAll(keepingCapacity: true)
        for (snapshot, rate) in metrics {
            if let packet = formatMetric(snapshot, sampleRate: rate) {
                buffer.append(packet)
            } else {
                reportError(MetricsError.invalidData("Aggregate cannot be encoded as a StatsD packet"))
            }
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
