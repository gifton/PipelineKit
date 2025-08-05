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
    public func listExporters() async -> [String: ExporterInfo] {
        await withTaskGroup(of: (String, ExporterInfo).self) { group in
            for (name, wrapper) in exporters {
                group.addTask {
                    let info = ExporterInfo(
                        name: name,
                        isActive: await wrapper.isActive(),
                        queueDepth: await wrapper.queueDepth(),
                        successCount: await wrapper.successCount,
                        failureCount: await wrapper.failureCount,
                        circuitBreakerState: await wrapper.circuitBreakerState()
                    )
                    return (name, info)
                }
            }
            
            var results: [String: ExporterInfo] = [:]
            for await (name, info) in group {
                results[name] = info
            }
            return results
        }
    }
    
    // MARK: - Export Operations
    
    /// Exports a metric to all active exporters.
    public func export(_ metric: MetricDataPoint) async {
        guard !isShuttingDown else { return }
        
        for (_, wrapper) in exporters where await wrapper.isActive() {
            if await !wrapper.enqueue(metric) && configuration.dropOnOverflow {
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
        
        for (_, wrapper) in exporters {
            if await wrapper.isActive() {
                Task {
                    do {
                        try await wrapper.exporter.exportAggregated(metrics)
                        await wrapper.recordSuccess()
                    } catch {
                        await wrapper.recordFailure(error)
                    }
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
    public func statistics() async -> ExportManagerStatistics {
        var activeCount = 0
        for wrapper in exporters.values {
            if await wrapper.isActive() {
                activeCount += 1
            }
        }
        
        return ExportManagerStatistics(
            exporterCount: exporters.count,
            activeExporters: activeCount,
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
                await wrapper.checkCircuitBreaker()
            }
            
            try? await Task.sleep(nanoseconds: UInt64(configuration.healthCheckInterval * 1_000_000_000))
        }
    }
}

// MARK: - ExporterWrapper

/// Wraps an exporter with queue management and circuit breaker.
private actor ExporterWrapper {
    let name: String
    let exporter: any MetricExporter
    private let maxQueueDepth: Int
    private let circuitBreakerThreshold: Int
    private let circuitBreakerResetTime: TimeInterval
    
    private var queue: [MetricDataPoint] = []
    
    private(set) var successCount: Int = 0
    private(set) var failureCount: Int = 0
    private var consecutiveFailures: Int = 0
    private var circuitBreakerOpenTime: Date?
    
    func isActive() -> Bool {
        circuitBreakerState() == .closed
    }
    
    func queueDepth() -> Int {
        queue.count
    }
    
    func circuitBreakerState() -> CircuitBreakerState {
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
        guard circuitBreakerState() != .open else { return false }
        guard queue.count < maxQueueDepth else { return false }
        queue.append(metric)
        return true
    }
    
    func processQueue() async {
        guard circuitBreakerState() != .open else { return }
        
        let batch = queue
        queue.removeAll(keepingCapacity: true)
        
        guard !batch.isEmpty else { return }
        
        do {
            try await exporter.exportBatch(batch)
            recordSuccess()
        } catch {
            recordFailure(error)
            
            // Re-queue if circuit breaker isn't open
            if circuitBreakerState() != .open {
                queue.insert(contentsOf: batch, at: 0)
            }
        }
    }
    
    func recordSuccess() {
        successCount += 1
        consecutiveFailures = 0
        
        // Reset circuit breaker if half-open
        if circuitBreakerState() == .halfOpen {
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
        if circuitBreakerState() == .halfOpen {
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
