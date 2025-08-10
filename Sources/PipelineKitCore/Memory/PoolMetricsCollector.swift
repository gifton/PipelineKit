import Foundation
#if canImport(os)
import os
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

    /// Metrics export handler
    public typealias MetricsExporter = @Sendable (PoolMetricsSnapshot) async -> Void
    private var exporters: [UUID: MetricsExporter] = [:]

    /// Alert thresholds
    private var alertThresholds = AlertThresholds()

    /// Creates a new metrics collector.
    ///
    /// - Parameters:
    ///   - collectionInterval: How often to collect metrics (default: 30 seconds)
    ///   - maxHistorySize: Maximum number of snapshots to retain (default: 1000)
    public init(
        collectionInterval: TimeInterval = 30,
        maxHistorySize: Int = 1000
    ) {
        self.collectionInterval = collectionInterval
        self.maxHistorySize = maxHistorySize
    }

    /// Starts collecting metrics.
    public func startCollecting() {
        guard collectionTask == nil else { return }

        collectionTask = Task {
            await collectMetricsPeriodically()
        }
    }

    /// Stops collecting metrics.
    public func stopCollecting() {
        collectionTask?.cancel()
        collectionTask = nil
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
        await collectSnapshot()
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

    private func collectMetricsPeriodically() async {
        while !Task.isCancelled {
            let snapshot = await collectSnapshot()

            // Store in history
            metricsHistory.append(snapshot)
            if metricsHistory.count > maxHistorySize {
                metricsHistory.removeFirst()
            }

            // Check alerts
            await checkAlerts(snapshot)

            // Export to registered handlers
            await exportSnapshot(snapshot)

            // Wait for next collection
            try? await Task.sleep(nanoseconds: UInt64(collectionInterval * 1_000_000_000))
        }
    }

    private func collectSnapshot() async -> PoolMetricsSnapshot {
        // TODO: Implement pool registry for collecting stats from all pools
        let poolStats: [(name: String, stats: ObjectPoolStatistics)] = []
        // TODO: Implement memory pressure detection
        let memoryPressureEvents = 0

        // Calculate overall metrics from individual pool stats
        let overallHitRate = poolStats.isEmpty ? 0.0 :
            poolStats.reduce(0.0) { $0 + $1.stats.hitRate } / Double(poolStats.count) * 100.0
        let totalAllocations = poolStats.reduce(0) { $0 + $1.stats.totalAllocated }

        return PoolMetricsSnapshot(
            timestamp: Date(),
            poolStatistics: poolStats,
            overallHitRate: overallHitRate,
            overallEfficiency: 0.0, // TODO: Calculate efficiency metric
            totalAllocations: totalAllocations,
            memoryPressureEvents: memoryPressureEvents,
            currentMemoryUsage: getMemoryUsage()
        )
    }

    private func checkAlerts(_ snapshot: PoolMetricsSnapshot) async {
        // Check hit rate threshold
        if snapshot.overallHitRate < alertThresholds.minHitRate {
            #if canImport(os)
            logger.warning("Pool hit rate below threshold: \(String(format: "%.1f", snapshot.overallHitRate))%")
            #endif
            await sendAlert(.lowHitRate(snapshot.overallHitRate))
        }

        // Check efficiency threshold
        if snapshot.overallEfficiency < alertThresholds.minEfficiency {
            #if canImport(os)
            logger.warning("Pool efficiency below threshold: \(String(format: "%.2f", snapshot.overallEfficiency))")
            #endif
            await sendAlert(.lowEfficiency(snapshot.overallEfficiency))
        }

        // Check allocation rate
        if let lastSnapshot = metricsHistory.last {
            let timeDelta = snapshot.timestamp.timeIntervalSince(lastSnapshot.timestamp)
            let allocationDelta = snapshot.totalAllocations - lastSnapshot.totalAllocations
            let allocationRate = Double(allocationDelta) / timeDelta

            if allocationRate > alertThresholds.maxAllocationRate {
                #if canImport(os)
                logger.warning("High allocation rate: \(String(format: "%.1f", allocationRate)) allocations/second")
                #endif
                await sendAlert(.highAllocationRate(allocationRate))
            }
        }
    }

    private func exportSnapshot(_ snapshot: PoolMetricsSnapshot) async {
        await withTaskGroup(of: Void.self) { group in
            for exporter in exporters.values {
                group.addTask {
                    await exporter(snapshot)
                }
            }
        }
    }

    private func sendAlert(_ alert: PoolAlert) async {
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

        await exportSnapshot(alertSnapshot)
    }

    private func getMemoryUsage() -> Int {
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
