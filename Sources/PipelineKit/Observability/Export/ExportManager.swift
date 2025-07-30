import Foundation

/// Manages metric exporters and coordinates export operations.
///
/// ExportManager is the central coordinator for all export operations.
/// It manages exporter lifecycle, routes metrics to appropriate exporters,
/// handles failures, and provides back-pressure when needed.
///
/// ## Features
/// - Dynamic exporter registration
/// - Failure isolation between exporters
/// - Back-pressure monitoring
/// - Circuit breaker for failing exporters
/// - Export metrics collection
public actor ExportManager {
    /// Configuration for the export manager.
    public struct Configuration: Sendable {
        /// Maximum number of metrics to queue per exporter.
        public let maxQueueDepth: Int
        
        /// How often to check exporter health.
        public let healthCheckInterval: TimeInterval
        
        /// Number of failures before circuit breaker opens.
        public let circuitBreakerThreshold: Int
        
        /// How long to wait before retrying a failed exporter.
        public let circuitBreakerResetTime: TimeInterval
        
        /// Whether to drop metrics when queues are full.
        public let dropOnOverflow: Bool
        
        public init(
            maxQueueDepth: Int = 10_000,
            healthCheckInterval: TimeInterval = 30.0,
            circuitBreakerThreshold: Int = 5,
            circuitBreakerResetTime: TimeInterval = 60.0,
            dropOnOverflow: Bool = true
        ) {
            self.maxQueueDepth = maxQueueDepth
            self.healthCheckInterval = healthCheckInterval
            self.circuitBreakerThreshold = circuitBreakerThreshold
            self.circuitBreakerResetTime = circuitBreakerResetTime
            self.dropOnOverflow = dropOnOverflow
        }
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private var exporters: [String: ExporterWrapper] = [:]
    private var healthCheckTask: Task<Void, Never>?
    private var isShuttingDown = false
    
    // Metrics
    private var totalExported: Int = 0
    private var totalDropped: Int = 0
    private var lastExportTime: Date?
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    // MARK: - Exporter Management
    
    /// Returns the number of registered exporters.
    public func exporterCount() -> Int {
        exporters.count
    }
    
    /// Registers an exporter with the given name.
    public func register(_ exporter: any MetricExporter, name: String) async {
        guard !isShuttingDown else { return }
        
        let wrapper = ExporterWrapper(
            name: name,
            exporter: exporter,
            maxQueueDepth: configuration.maxQueueDepth,
            circuitBreakerThreshold: configuration.circuitBreakerThreshold,
            circuitBreakerResetTime: configuration.circuitBreakerResetTime
        )
        
        exporters[name] = wrapper
        
        // Start health monitoring if not already running
        if healthCheckTask == nil {
            healthCheckTask = Task {
                await runHealthChecks()
            }
        }
    }
    
    /// Unregisters an exporter.
    public func unregister(_ name: String) async {
        if let wrapper = exporters.removeValue(forKey: name) {
            await wrapper.shutdown()
        }
    }
    
    /// Lists all registered exporters.
    public func listExporters() -> [String: ExporterInfo] {
        var info: [String: ExporterInfo] = [:]
        
        for (name, wrapper) in exporters {
            info[name] = ExporterInfo(
                name: name,
                isActive: wrapper.isActive,
                queueDepth: wrapper.queueDepth,
                successCount: wrapper.successCount,
                failureCount: wrapper.failureCount,
                circuitBreakerState: wrapper.circuitBreakerState
            )
        }
        
        return info
    }
    
    // MARK: - Export Operations
    
    /// Exports a metric to all active exporters.
    public func export(_ metric: MetricDataPoint) async {
        guard !isShuttingDown else { return }
        
        for (_, wrapper) in exporters where wrapper.isActive {
            if !wrapper.enqueue(metric) && configuration.dropOnOverflow {
                totalDropped += 1
            }
        }
        
        totalExported += 1
        lastExportTime = Date()
    }
    
    /// Exports a batch of metrics to all active exporters.
    public func exportBatch(_ metrics: [MetricDataPoint]) async {
        guard !isShuttingDown else { return }
        
        for metric in metrics {
            await export(metric)
        }
    }
    
    /// Exports aggregated metrics to all active exporters.
    public func exportAggregated(_ metrics: [AggregatedMetrics]) async {
        guard !isShuttingDown else { return }
        
        for (_, wrapper) in exporters where wrapper.isActive {
            Task {
                do {
                    try await wrapper.exporter.exportAggregated(metrics)
                    wrapper.recordSuccess()
                } catch {
                    wrapper.recordFailure(error)
                }
            }
        }
    }
    
    /// Forces all exporters to flush their buffers.
    public func flushAll() async {
        await withTaskGroup(of: Void.self) { group in
            for (_, wrapper) in exporters {
                group.addTask {
                    try? await wrapper.exporter.flush()
                }
            }
        }
    }
    
    // MARK: - Lifecycle
    
    /// Starts the export manager.
    public func start() {
        if healthCheckTask == nil {
            healthCheckTask = Task {
                await runHealthChecks()
            }
        }
    }
    
    /// Shuts down the export manager and all exporters.
    public func shutdown() async {
        isShuttingDown = true
        healthCheckTask?.cancel()
        
        // Shutdown all exporters
        await withTaskGroup(of: Void.self) { group in
            for (_, wrapper) in exporters {
                group.addTask {
                    await wrapper.shutdown()
                }
            }
        }
        
        exporters.removeAll()
    }
    
    /// Returns current statistics.
    public func statistics() -> ExportManagerStatistics {
        ExportManagerStatistics(
            exporterCount: exporters.count,
            activeExporters: exporters.values.filter { $0.isActive }.count,
            totalExported: totalExported,
            totalDropped: totalDropped,
            lastExportTime: lastExportTime
        )
    }
    
    // MARK: - Private Methods
    
    private func runHealthChecks() async {
        while !Task.isCancelled && !isShuttingDown {
            // Process queued metrics for each exporter
            for (_, wrapper) in exporters {
                await wrapper.processQueue()
            }
            
            // Check circuit breakers
            for (_, wrapper) in exporters {
                wrapper.checkCircuitBreaker()
            }
            
            try? await Task.sleep(nanoseconds: UInt64(configuration.healthCheckInterval * 1_000_000_000))
        }
    }
}

// MARK: - ExporterWrapper

/// Wraps an exporter with queue management and circuit breaker.
private final class ExporterWrapper {
    let name: String
    let exporter: any MetricExporter
    private let maxQueueDepth: Int
    private let circuitBreakerThreshold: Int
    private let circuitBreakerResetTime: TimeInterval
    
    private var queue: [MetricDataPoint] = []
    private let queueLock = NSLock()
    
    private(set) var successCount: Int = 0
    private(set) var failureCount: Int = 0
    private var consecutiveFailures: Int = 0
    private var circuitBreakerOpenTime: Date?
    
    var isActive: Bool {
        circuitBreakerState == .closed
    }
    
    var queueDepth: Int {
        queueLock.withLock { queue.count }
    }
    
    var circuitBreakerState: CircuitBreakerState {
        if let openTime = circuitBreakerOpenTime {
            if Date().timeIntervalSince(openTime) > circuitBreakerResetTime {
                return .halfOpen
            }
            return .open
        }
        return .closed
    }
    
    init(
        name: String,
        exporter: any MetricExporter,
        maxQueueDepth: Int,
        circuitBreakerThreshold: Int,
        circuitBreakerResetTime: TimeInterval
    ) {
        self.name = name
        self.exporter = exporter
        self.maxQueueDepth = maxQueueDepth
        self.circuitBreakerThreshold = circuitBreakerThreshold
        self.circuitBreakerResetTime = circuitBreakerResetTime
    }
    
    func enqueue(_ metric: MetricDataPoint) -> Bool {
        guard circuitBreakerState != .open else { return false }
        
        return queueLock.withLock {
            guard queue.count < maxQueueDepth else { return false }
            queue.append(metric)
            return true
        }
    }
    
    func processQueue() async {
        guard circuitBreakerState != .open else { return }
        
        let batch = queueLock.withLock {
            let items = queue
            queue.removeAll(keepingCapacity: true)
            return items
        }
        
        guard !batch.isEmpty else { return }
        
        do {
            try await exporter.exportBatch(batch)
            recordSuccess()
        } catch {
            recordFailure(error)
            
            // Re-queue if circuit breaker isn't open
            if circuitBreakerState != .open {
                queueLock.withLock {
                    queue.insert(contentsOf: batch, at: 0)
                }
            }
        }
    }
    
    func recordSuccess() {
        successCount += 1
        consecutiveFailures = 0
        
        // Reset circuit breaker if half-open
        if circuitBreakerState == .halfOpen {
            circuitBreakerOpenTime = nil
        }
    }
    
    func recordFailure(_ error: Error) {
        failureCount += 1
        consecutiveFailures += 1
        
        if consecutiveFailures >= circuitBreakerThreshold {
            circuitBreakerOpenTime = Date()
        }
    }
    
    func checkCircuitBreaker() {
        if circuitBreakerState == .halfOpen {
            // Reset failure count for half-open state
            consecutiveFailures = 0
        }
    }
    
    func shutdown() async {
        await processQueue()
        await exporter.shutdown()
    }
}

// MARK: - Supporting Types

/// Information about a registered exporter.
public struct ExporterInfo: Sendable {
    public let name: String
    public let isActive: Bool
    public let queueDepth: Int
    public let successCount: Int
    public let failureCount: Int
    public let circuitBreakerState: CircuitBreakerState
}

/// Circuit breaker states.
public enum CircuitBreakerState: String, Sendable {
    case closed = "closed"
    case open = "open"
    case halfOpen = "half-open"
}

/// Export manager statistics.
public struct ExportManagerStatistics: Sendable {
    public let exporterCount: Int
    public let activeExporters: Int
    public let totalExported: Int
    public let totalDropped: Int
    public let lastExportTime: Date?
}

// MARK: - Thread-Safe Lock Helper

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}