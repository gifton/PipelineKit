import Foundation
#if os(Linux)
@preconcurrency import Glibc
#else
@preconcurrency import Darwin
#endif
import PipelineKitCore
#if canImport(os)
@preconcurrency import os
#endif

/// Collects and reports metrics from object pools for production monitoring.
///
/// This component provides hooks for tracking pool efficiency, memory usage,
/// and performance regressions in production environments.
public actor PoolMetricsCollector {
    /// Metric collection interval in seconds
    private let collectionInterval: TimeInterval

    /// Metrics storage for time-series data
    private var metricsHistory: [PoolMetricsSnapshot] = []

    /// Maximum history size
    private let maxHistorySize: Int

    /// Logger for metrics
    #if canImport(os)
    private let logger = Logger(subsystem: "PipelineKit", category: "PoolMetrics")
    #endif

    /// Collection task
    private var collectionTask: Task<Void, Never>?
    private var collectionGeneration: UUID?
    private var previousSnapshot: PoolMetricsSnapshot?
    private let snapshotProvider: @Sendable () async -> PoolMetricsSnapshot
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let memoryPressure: PoolMetricsMemoryPressureClient

    /// Metrics export handler
    public typealias MetricsExporter = @Sendable (PoolMetricsSnapshot) async -> Void
    private var exporters: [UUID: MetricsExporter] = [:]

    /// Alert thresholds
    private var alertThresholds = AlertThresholds()
    
    /// Memory pressure handler registration ID
    private var memoryPressureHandlerID: UUID?

    /// Creates a new metrics collector.
    ///
    /// - Parameters:
    ///   - collectionInterval: How often to collect metrics (default: 30 seconds)
    ///   - maxHistorySize: Maximum number of snapshots to retain (default: 1000)
    public init(
        collectionInterval: TimeInterval = 30,
        maxHistorySize: Int = 1000
    ) {
        self.init(
            collectionInterval: collectionInterval,
            maxHistorySize: maxHistorySize,
            snapshotProvider: Self.liveSnapshot,
            sleep: { try await Task.sleep(nanoseconds: $0) },
            memoryPressure: .live
        )
    }

    init(
        collectionInterval: TimeInterval = 30,
        maxHistorySize: Int = 1000,
        snapshotProvider: @escaping @Sendable () async -> PoolMetricsSnapshot,
        sleep: @escaping @Sendable (UInt64) async throws -> Void,
        memoryPressure: PoolMetricsMemoryPressureClient = .live
    ) {
        _ = NumericDuration.nanoseconds(collectionInterval, positive: true)
        precondition(maxHistorySize >= 0, "Pool metrics history size must be nonnegative")
        self.collectionInterval = collectionInterval
        self.maxHistorySize = maxHistorySize
        self.snapshotProvider = snapshotProvider
        self.sleep = sleep
        self.memoryPressure = memoryPressure
    }

    deinit {
        collectionTask?.cancel()
        if let handlerID = memoryPressureHandlerID {
            let unregister = memoryPressure.unregister
            Task { await unregister(handlerID) }
        }
    }

    /// Starts one collection run. A repeated start while active is ignored.
    public func startCollecting() async {
        guard collectionTask == nil else { return }
        let generation = UUID()
        collectionGeneration = generation
        let snapshotProvider = self.snapshotProvider
        let sleep = self.sleep
        let nanoseconds = NumericDuration.nanoseconds(collectionInterval, positive: true)
        collectionTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await snapshotProvider()
                guard !Task.isCancelled,
                      await self?.processSnapshot(snapshot, generation: generation) == true else { return }
                // The actor is not retained during the interval between collections.
                do { try await sleep(nanoseconds) } catch { return }
            }
        }

        let handlerID = await memoryPressure.register { [weak self] in
            await self?.handleMemoryPressure(generation: generation)
        }
        guard collectionGeneration == generation else {
            await memoryPressure.unregister(handlerID)
            return
        }
        memoryPressureHandlerID = handlerID
        await memoryPressure.start()
    }

    /// Stops future collection and clears history, the previous sample, and exporters.
    /// Already invoked exporters may finish; this does not wait for them, so an
    /// exporter may call stopCollecting without waiting on its own task.
    public func stopCollecting() async {
        collectionGeneration = nil
        collectionTask?.cancel()
        collectionTask = nil
        let handlerID = memoryPressureHandlerID
        memoryPressureHandlerID = nil
        exporters.removeAll()
        metricsHistory.removeAll()
        previousSnapshot = nil
        if let handlerID { await memoryPressure.unregister(handlerID) }
    }

    /// Registers a metrics exporter.
    ///
    /// - Parameter exporter: Closure to handle metric snapshots
    /// - Returns: Registration ID for unregistering
    @discardableResult
    public func registerExporter(_ exporter: @escaping MetricsExporter) -> UUID {
        let id = UUID()
        exporters[id] = exporter
        return id
    }

    /// Unregisters a metrics exporter.
    public func unregisterExporter(id: UUID) {
        exporters.removeValue(forKey: id)
    }

    /// Configures alert thresholds.
    public func configureAlerts(_ thresholds: AlertThresholds) {
        self.alertThresholds = thresholds
    }

    /// Gets current metrics snapshot.
    public func currentSnapshot() async -> PoolMetricsSnapshot {
        await snapshotProvider()
    }

    /// Gets metrics history.
    public var history: [PoolMetricsSnapshot] {
        metricsHistory
    }

    /// Gets performance regression analysis.
    public func analyzeRegressions() -> RegressionAnalysis {
        guard metricsHistory.count >= 10 else {
            return RegressionAnalysis(hasRegression: false, details: "Insufficient data")
        }

        // **ultrathink**: Analyze trends using sliding window approach
        // This detects gradual performance degradation that might not trigger immediate alerts
        let recentMetrics = Array(metricsHistory.suffix(10))
        let olderMetrics = Array(metricsHistory.dropLast(10).suffix(10))

        guard !olderMetrics.isEmpty else {
            return RegressionAnalysis(hasRegression: false, details: "Insufficient historical data")
        }

        // Compare average metrics
        let recentAvgHitRate = recentMetrics.reduce(0.0) { $0 + $1.overallHitRate } / Double(recentMetrics.count)
        let olderAvgHitRate = olderMetrics.reduce(0.0) { $0 + $1.overallHitRate } / Double(olderMetrics.count)

        let recentAvgEfficiency = recentMetrics.reduce(0.0) { $0 + $1.overallEfficiency } / Double(recentMetrics.count)
        let olderAvgEfficiency = olderMetrics.reduce(0.0) { $0 + $1.overallEfficiency } / Double(olderMetrics.count)

        // Detect significant degradation
        let hitRateDrop = olderAvgHitRate - recentAvgHitRate
        let efficiencyDrop = olderAvgEfficiency - recentAvgEfficiency

        if hitRateDrop > 10 || efficiencyDrop > 0.5 {
            return RegressionAnalysis(
                hasRegression: true,
                details: "Performance regression detected: Hit rate dropped by \(String(format: "%.1f", hitRateDrop))%, efficiency dropped by \(String(format: "%.2f", efficiencyDrop))",
                hitRateDrop: hitRateDrop,
                efficiencyDrop: efficiencyDrop
            )
        }

        return RegressionAnalysis(hasRegression: false, details: "No regression detected")
    }

    // MARK: - Private Methods

    private func processSnapshot(_ snapshot: PoolMetricsSnapshot, generation: UUID) async -> Bool {
        guard isCurrent(generation) else { return false }
        let previous = previousSnapshot
        previousSnapshot = snapshot
        if maxHistorySize > 0 {
            metricsHistory.append(snapshot)
            if metricsHistory.count > maxHistorySize { metricsHistory.removeFirst() }
        }

        for alert in alerts(for: snapshot, previous: previous) {
            guard isCurrent(generation) else { return false }
            await sendAlert(alert, generation: generation)
        }
        guard isCurrent(generation) else { return false }
        await exportSnapshot(snapshot, generation: generation)
        return isCurrent(generation)
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        collectionGeneration == generation && !Task.isCancelled
    }

    private nonisolated static func liveSnapshot() async -> PoolMetricsSnapshot {
        // Collect stats from all registered pools
        let poolStats = await PoolRegistry.shared.getAllStatistics()
        
        // Get aggregated metrics
        let aggregated = await PoolRegistry.shared.getAggregatedStatistics()
        
        // Get memory pressure events from the detector
        let pressureStats = await MemoryPressureDetector.shared.statistics
        let memoryPressureEvents = pressureStats.pressureEvents

        return PoolMetricsSnapshot(
            timestamp: Date(),
            poolStatistics: poolStats,
            overallHitRate: aggregated.overallHitRate,
            overallEfficiency: aggregated.overallEfficiency,
            totalAllocations: aggregated.totalAllocated,
            memoryPressureEvents: memoryPressureEvents,
            currentMemoryUsage: getMemoryUsage()
        )
    }

    private func alerts(for snapshot: PoolMetricsSnapshot, previous: PoolMetricsSnapshot?) -> [PoolAlert] {
        var alerts: [PoolAlert] = []
        if snapshot.overallHitRate < alertThresholds.minHitRate {
            #if canImport(os)
            logger.warning("Pool hit rate below threshold: \(String(format: "%.1f", snapshot.overallHitRate))%")
            #endif
            alerts.append(.lowHitRate(snapshot.overallHitRate))
        }
        if snapshot.overallEfficiency < alertThresholds.minEfficiency {
            #if canImport(os)
            logger.warning("Pool efficiency below threshold: \(String(format: "%.2f", snapshot.overallEfficiency))")
            #endif
            alerts.append(.lowEfficiency(snapshot.overallEfficiency))
        }
        if let previous,
           let rate = Self.allocationRate(from: previous, to: snapshot),
           rate > alertThresholds.maxAllocationRate {
            #if canImport(os)
            logger.warning("High allocation rate: \(String(format: "%.1f", rate)) allocations/second")
            #endif
            alerts.append(.highAllocationRate(rate))
        }
        return alerts
    }

    /// A missing interval or reset aggregate establishes a new baseline, not a rate.
    static func allocationRate(from previous: PoolMetricsSnapshot, to current: PoolMetricsSnapshot) -> Double? {
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed.isFinite, elapsed > 0,
              previous.totalAllocations >= 0,
              current.totalAllocations >= previous.totalAllocations else { return nil }
        let delta = current.totalAllocations - previous.totalAllocations
        let rate = Double(delta) / elapsed
        return rate.isFinite ? rate : nil
    }

    private func exportSnapshot(_ snapshot: PoolMetricsSnapshot, generation: UUID) async {
        guard isCurrent(generation) else { return }
        let handlers = Array(exporters.values)
        await withTaskGroup(of: Void.self) { group in
            for exporter in handlers {
                group.addTask { [weak self] in
                    await self?.deliver(snapshot, to: exporter, generation: generation)
                }
            }
        }
    }

    private func deliver(_ snapshot: PoolMetricsSnapshot, to exporter: MetricsExporter, generation: UUID) async {
        guard isCurrent(generation) else { return }
        await exporter(snapshot)
    }

    private func sendAlert(_ alert: PoolAlert, generation: UUID) async {
        // Export alert through registered handlers
        let alertSnapshot = PoolMetricsSnapshot(
            timestamp: Date(),
            poolStatistics: [],
            overallHitRate: 0,
            overallEfficiency: 0,
            totalAllocations: 0,
            memoryPressureEvents: 0,
            currentMemoryUsage: 0,
            alert: alert
        )

        await exportSnapshot(alertSnapshot, generation: generation)
    }

    private func handleMemoryPressure(generation: UUID) async {
        guard isCurrent(generation) else { return }
        let pressureLevel = await MemoryPressureDetector.shared.pressureLevel
        guard isCurrent(generation) else { return }
        #if canImport(os)
        logger.warning("Memory pressure detected: \(String(describing: pressureLevel))")
        #endif
        await sendAlert(.memoryPressure(pressureLevel), generation: generation)
        guard isCurrent(generation) else { return }
        await shrinkPoolsForPressureLevel(pressureLevel)
    }

    private func shrinkPoolsForPressureLevel(_ level: MemoryPressureLevel) async {
        switch level {
        case .normal:
            // No action needed
            return
            
        case .warning:
            // Use intelligent shrinking if possible
            #if canImport(os)
            logger.info("Memory warning: Intelligently shrinking pools based on usage patterns")
            #endif
            await PoolRegistry.shared.shrinkAllPoolsIntelligently(
                pressureLevel: level,
                collector: self,
                force: false
            )
            
        case .critical:
            // Use intelligent shrinking but force it for critical pressure
            #if canImport(os)
            logger.warning("Memory critical: Force intelligent shrinking of all pools")
            #endif
            await PoolRegistry.shared.shrinkAllPoolsIntelligently(
                pressureLevel: level,
                collector: self,
                force: true
            )
        }
    }
    
    private nonisolated static func getMemoryUsage() -> Int {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        #else
        // On Linux, we can try to read from /proc/self/status
        // For now, return 0 as a placeholder
        return 0
        #endif
    }
}

/// Async operations at the shared memory-pressure detector boundary.
struct PoolMetricsMemoryPressureClient: Sendable {
    var register: @Sendable (@escaping @Sendable () async -> Void) async -> UUID
    var unregister: @Sendable (UUID) async -> Void
    var start: @Sendable () async -> Void

    static let live = Self(
        register: { await MemoryPressureDetector.shared.register(handler: $0) },
        unregister: { await MemoryPressureDetector.shared.unregister(id: $0) },
        start: { await MemoryPressureDetector.shared.startMonitoring() }
    )
}

// MARK: - Supporting Types

/// Snapshot of pool metrics at a point in time.
public struct PoolMetricsSnapshot: Sendable {
    public let timestamp: Date
    public let poolStatistics: [(name: String, stats: ObjectPoolStatistics)]
    public let overallHitRate: Double
    public let overallEfficiency: Double
    public let totalAllocations: Int
    public let memoryPressureEvents: Int
    public let currentMemoryUsage: Int
    public let alert: PoolAlert?

    public init(
        timestamp: Date,
        poolStatistics: [(name: String, stats: ObjectPoolStatistics)],
        overallHitRate: Double,
        overallEfficiency: Double,
        totalAllocations: Int,
        memoryPressureEvents: Int,
        currentMemoryUsage: Int,
        alert: PoolAlert? = nil
    ) {
        self.timestamp = timestamp
        self.poolStatistics = poolStatistics
        self.overallHitRate = overallHitRate
        self.overallEfficiency = overallEfficiency
        self.totalAllocations = totalAllocations
        self.memoryPressureEvents = memoryPressureEvents
        self.currentMemoryUsage = currentMemoryUsage
        self.alert = alert
    }
}

/// Alert thresholds for monitoring.
public struct AlertThresholds: Sendable {
    /// Minimum acceptable hit rate (default: 70%)
    public var minHitRate: Double = 70.0

    /// Minimum acceptable efficiency (default: 2.0)
    public var minEfficiency: Double = 2.0

    /// Maximum allocation rate per second (default: 1000)
    public var maxAllocationRate: Double = 1000.0

    public init() {}
}

/// Pool-related alerts.
public enum PoolAlert: Sendable {
    case lowHitRate(Double)
    case lowEfficiency(Double)
    case highAllocationRate(Double)
    case memoryPressure(MemoryPressureLevel)
}

/// Regression analysis result.
public struct RegressionAnalysis: Sendable {
    public let hasRegression: Bool
    public let details: String
    public let hitRateDrop: Double?
    public let efficiencyDrop: Double?

    public init(
        hasRegression: Bool,
        details: String,
        hitRateDrop: Double? = nil,
        efficiencyDrop: Double? = nil
    ) {
        self.hasRegression = hasRegression
        self.details = details
        self.hitRateDrop = hitRateDrop
        self.efficiencyDrop = efficiencyDrop
    }
}
