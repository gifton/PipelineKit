import Foundation
import Atomics
import PipelineKitCore

/// Registry for tracking active object pools for metrics collection.
///
/// This registry maintains weak references to all registered pools,
/// allowing centralized metrics collection without creating retain cycles.
public actor PoolRegistry {
    // MARK: - Singleton
    
    /// Shared registry instance
    public static let shared = PoolRegistry()
    
    // MARK: - Configuration

    /// Whether metrics are enabled by default for new pools (thread-safe)
    private static let _metricsEnabledByDefault = ManagedAtomic(false)
    public static var metricsEnabledByDefault: Bool {
        get { _metricsEnabledByDefault.load(ordering: .relaxed) }
        set { _metricsEnabledByDefault.store(newValue, ordering: .relaxed) }
    }

    /// Cleanup interval for removing dead weak references (seconds; thread-safe)
    private static let _cleanupIntervalSeconds = ManagedAtomic<Int64>(30)
    public static var cleanupInterval: TimeInterval {
        get { TimeInterval(_cleanupIntervalSeconds.load(ordering: .relaxed)) }
        set { _cleanupIntervalSeconds.store(Int64(newValue), ordering: .relaxed) }
    }

    /// Minimum interval between pool shrink operations (seconds; thread-safe)
    private static let _minimumShrinkIntervalSeconds = ManagedAtomic<Int64>(10)
    public static var minimumShrinkInterval: TimeInterval {
        get { TimeInterval(_minimumShrinkIntervalSeconds.load(ordering: .relaxed)) }
        set { _minimumShrinkIntervalSeconds.store(Int64(newValue), ordering: .relaxed) }
    }

    /// Enable intelligent shrinking based on usage patterns (thread-safe)
    private static let _intelligentShrinkingEnabled = ManagedAtomic(true)
    public static var intelligentShrinkingEnabled: Bool {
        get { _intelligentShrinkingEnabled.load(ordering: .relaxed) }
        set { _intelligentShrinkingEnabled.store(newValue, ordering: .relaxed) }
    }
    
    // MARK: - Private Properties
    
    private var pools: [ObjectIdentifier: WeakPoolBox] = [:]
    private var cleanupTask: Task<Void, Never>?
    private static let poolCounters = ManagedAtomic<Int>(0)
    private var throttledRequestsCount = 0
    
    // MARK: - Initialization
    
    private init() {
        // Validate cleanup interval in debug builds only
        precondition(Self.cleanupInterval > 0,
                     "PoolRegistry.cleanupInterval must be positive (got \(Self.cleanupInterval))")
        
        // Ensure a sane value even if precondition is stripped in release
        let safeInterval = max(Self.cleanupInterval, 1.0)
        
        Task { [weak self] in
            await self?.startCleanupTaskWithInterval(safeInterval)
        }
    }
    
    // MARK: - Registration
    
    /// Register a pool for metrics collection
    public func register<T: Sendable>(_ pool: ObjectPool<T>) {
        let box = WeakPoolBox(pool: pool)
        pools[box.id] = box
        
        // Opportunistic cleanup
        cleanupDeadEntries()
    }
    
    /// Unregister a pool (called from deinit)
    /// This is nonisolated so it can be called from deinit
    nonisolated public func unregister(id: ObjectIdentifier) {
        Task(priority: .utility) { [weak self] in
            await self?.remove(id)
        }
    }
    
    private func remove(_ id: ObjectIdentifier) {
        pools.removeValue(forKey: id)
    }
    
    // MARK: - Statistics Collection
    
    /// Get statistics from all registered pools
    public func getAllStatistics() async -> [(name: String, stats: ObjectPoolStatistics)] {
        cleanupDeadEntries()
        
        var results: [(name: String, stats: ObjectPoolStatistics)] = []
        
        for (_, box) in pools where box.isAlive {
            if let stats = await box.getStatistics() {
                results.append((box.name, stats))
            }
        }
        
        return results
    }
    
    /// Get count of throttled shrink requests
    public var throttledRequests: Int {
        throttledRequestsCount
    }
    
    /// Increment throttled count (called from WeakPoolBox)
    func incrementThrottledCount() {
        throttledRequestsCount += 1
    }
    
    /// Get aggregated statistics across all pools
    public func getAggregatedStatistics() async -> AggregatedPoolStatistics {
        let allStats = await getAllStatistics()
        
        let totalHits = allStats.reduce(0) { $0 + $1.stats.hits }
        let totalMisses = allStats.reduce(0) { $0 + $1.stats.misses }
        let totalAllocated = allStats.reduce(0) { $0 + $1.stats.totalAllocated }
        let totalReused = totalHits  // Hits represent reused objects
        let activePoolCount = allStats.count
        
        let hitRate: Double
        let efficiency: Double
        
        if totalHits + totalMisses > 0 {
            hitRate = Double(totalHits) / Double(totalHits + totalMisses) * 100.0
            // Efficiency: how much memory we saved by reusing objects
            // Formula: (objects reused - objects allocated) / max(total requests, 1) * 100
            // This shows the percentage of requests that didn't require new allocations
            let totalRequests = totalHits + totalMisses
            let savedAllocations = max(0, totalHits - totalAllocated)
            efficiency = Double(savedAllocations) / Double(max(totalRequests, 1)) * 100.0
        } else {
            hitRate = 0.0
            efficiency = 0.0
        }
        
        return AggregatedPoolStatistics(
            activePoolCount: activePoolCount,
            totalHits: totalHits,
            totalMisses: totalMisses,
            totalAllocated: totalAllocated,
            totalReused: totalReused,
            overallHitRate: hitRate,
            overallEfficiency: efficiency
        )
    }
    
    // MARK: - Memory Management
    
    /// Request all pools to shrink to a target percentage of their maximum size
    /// - Parameters:
    ///   - percentage: Target percentage (0.0 to 1.0) of maximum pool size
    ///   - force: If true, bypass throttling (use sparingly for critical pressure)
    public func shrinkAllPools(toPercentage percentage: Double, force: Bool = false) async {
        // Validate and clamp percentage
        let clampedPercentage = max(0.0, min(1.0, percentage))
        
        cleanupDeadEntries()
        
        for (_, box) in pools where box.isAlive {
            await box.shrinkPool(toPercentage: clampedPercentage, force: force)
        }
    }
    
    /// Request all pools to shrink intelligently based on usage patterns
    /// - Parameters:
    ///   - pressureLevel: Current memory pressure level
    ///   - collector: Metrics collector with history for analysis
    ///   - force: If true, bypass throttling
    public func shrinkAllPoolsIntelligently(
        pressureLevel: MemoryPressureLevel,
        collector: PoolMetricsCollector?,
        force: Bool = false
    ) async {
        cleanupDeadEntries()
        
        // Check if intelligent shrinking is enabled
        guard Self.intelligentShrinkingEnabled else {
            // Fall back to simple percentage-based shrinking
            let percentage: Double = {
                switch pressureLevel {
                case .normal: return 1.0
                case .warning: return 0.5
                case .critical: return 0.2
                }
            }()
            await shrinkAllPools(toPercentage: percentage, force: force)
            return
        }
        
        // If no collector or not enough history, fall back to percentage-based
        guard let collector = collector else {
            let percentage: Double = {
                switch pressureLevel {
                case .normal: return 1.0
                case .warning: return 0.5
                case .critical: return 0.2
                }
            }()
            await shrinkAllPools(toPercentage: percentage, force: force)
            return
        }
        
        // Analyze each pool and shrink intelligently
        for (_, box) in pools where box.isAlive {
            // Get pool statistics
            guard let stats = await box.getStatistics() else { continue }
            
            // Analyze pool history
            if let analysis = await collector.analyzePoolHistory(box.name) {
                // Calculate intelligent target
                let target = IntelligentShrinker.calculateOptimalTarget(
                    pool: stats,
                    analysis: analysis,
                    pressureLevel: pressureLevel
                )
                
                // Apply intelligent shrinking
                await box.shrinkPool(to: target, force: force)
            } else {
                // Not enough history - use conservative shrinking
                let fallbackPercentage: Double = {
                    switch pressureLevel {
                    case .normal: return 1.0
                    case .warning: return 0.7  // More conservative than default
                    case .critical: return 0.3  // Less aggressive than default
                    }
                }()
                await box.shrinkPool(toPercentage: fallbackPercentage, force: force)
            }
        }
    }
    
    /// Request a specific pool to shrink
    /// - Parameters:
    ///   - name: Name of the pool to shrink
    ///   - targetSize: Target number of objects to keep (clamped to >= 0)
    ///   - force: If true, bypass throttling (use sparingly for critical pressure)
    public func shrinkPool(name: String, to targetSize: Int, force: Bool = false) async {
        // Validate and clamp target size
        let clampedSize = max(0, targetSize)
        
        cleanupDeadEntries()
        
        for (_, box) in pools where box.isAlive && box.name == name {
            await box.shrinkPool(to: clampedSize, force: force)
            break // Optimization: stop after finding the target pool
        }
    }
    
    // MARK: - Debug Support
    
    #if DEBUG
    /// Get detailed per-pool statistics (debug only)
    public func getDetailedStatistics() async -> [PoolDetailedStatistics] {
        cleanupDeadEntries()
        
        var results: [PoolDetailedStatistics] = []
        
        for (_, box) in pools where box.isAlive {
            if let stats = await box.getStatistics() {
                results.append(PoolDetailedStatistics(
                    name: box.name,
                    id: box.id,
                    stats: stats,
                    createdAt: box.createdAt
                ))
            }
        }
        
        return results
    }
    
    /// Dump all statistics to console (debug only)
    public func dumpAllStats() async {
        let detailed = await getDetailedStatistics()
        let aggregated = await getAggregatedStatistics()
        
        print("=== Pool Registry Statistics ===")
        print("Active Pools: \(aggregated.activePoolCount)")
        print("Overall Hit Rate: \(String(format: "%.1f%%", aggregated.overallHitRate))")
        print("Overall Efficiency: \(String(format: "%.1f%%", aggregated.overallEfficiency))")
        print("\nPer-Pool Statistics:")
        
        for detail in detailed {
            print("  \(detail.name):")
            print("    - Hits: \(detail.stats.hits)")
            print("    - Misses: \(detail.stats.misses)")
            print("    - Hit Rate: \(String(format: "%.1f%%", detail.stats.hitRate))")
            print("    - Total Allocated: \(detail.stats.totalAllocated)")
        }
    }
    #endif
    
    // MARK: - Cleanup
    
    private func cleanupDeadEntries() {
        pools = pools.filter { $0.value.isAlive }
    }
    
    private func startCleanupTaskWithInterval(_ interval: TimeInterval) {
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.cleanupDeadEntries()
            }
        }
    }
    
    deinit {
        cleanupTask?.cancel()
    }

    // MARK: - Shutdown

    /// Static shutdown method for test cleanup.
    /// This is called from test teardown observers to cancel background tasks so
    /// the process can exit cleanly after tests complete.
    public static func shutdown() {
        // Use a detached task to avoid isolation issues
        Task.detached {
            await shared._shutdown()
        }
    }

    private func _shutdown() {
        cleanupTask?.cancel()
        cleanupTask = nil
        pools.removeAll()
    }

    // MARK: - Name Generation
    
    /// Generate a unique name for a pool type
    public static func generatePoolName<T>(for type: T.Type) -> String {
        let counter = poolCounters.loadThenWrappingIncrement(ordering: .relaxed)
        return "\(type)-\(counter)"
    }
}

// MARK: - Supporting Types

/// Weak reference wrapper for object pools
private final class WeakPoolBox: @unchecked Sendable {
    weak var pool: AnyObject?
    let name: String
    let id: ObjectIdentifier
    let createdAt: Date
    private var lastShrinkTime: ContinuousClock.Instant?
    private let throttleLock = NSLock()
    private let getStatsFunc: @Sendable () async -> ObjectPoolStatistics?
    private let shrinkFunc: @Sendable (Int) async -> Void
    private let shrinkPercentageFunc: @Sendable (Double) async -> Void
    
    init<T: Sendable>(pool: ObjectPool<T>) {
        self.pool = pool
        self.name = pool.name
        self.id = ObjectIdentifier(pool)
        self.createdAt = Date()
        
        // Capture the async statistics getter with the correct type
        self.getStatsFunc = { @Sendable [weak pool] in
            guard let pool = pool else { return nil }
            return await pool.statistics
        }
        
        // Capture the shrink function
        self.shrinkFunc = { @Sendable [weak pool] targetSize in
            guard let pool = pool else { return }
            await pool.shrink(to: targetSize)
        }
        
        // Capture the percentage-based shrink function
        self.shrinkPercentageFunc = { @Sendable [weak pool] percentage in
            guard let pool = pool else { return }
            // Validate and clamp percentage
            let clampedPercentage = max(0.0, min(1.0, percentage))
            let stats = await pool.statistics
            // Use maxSize as the baseline for percentage calculation
            let targetSize = Int(Double(stats.maxSize) * clampedPercentage)
            await pool.shrink(to: targetSize)
        }
    }
    
    var isAlive: Bool {
        pool != nil
    }
    
    func getStatistics() async -> ObjectPoolStatistics? {
        await getStatsFunc()
    }
    
    func shrinkPool(to targetSize: Int, force: Bool = false) async {
        guard force || shouldAllowShrink() else {
            // Increment throttled count in registry
            await PoolRegistry.shared.incrementThrottledCount()
            return
        }
        updateLastShrinkTime()
        await shrinkFunc(targetSize)
    }
    
    func shrinkPool(toPercentage percentage: Double, force: Bool = false) async {
        guard force || shouldAllowShrink() else {
            // Increment throttled count in registry
            await PoolRegistry.shared.incrementThrottledCount()
            return
        }
        updateLastShrinkTime()
        await shrinkPercentageFunc(percentage)
    }
    
    private func shouldAllowShrink() -> Bool {
        // Skip throttling during first 30 seconds after startup
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime < 30.0 {
            return true
        }
        
        throttleLock.lock()
        defer { throttleLock.unlock() }
        
        guard let lastTime = lastShrinkTime else { return true }
        let elapsed = lastTime.duration(to: ContinuousClock.now)
        return elapsed >= Duration.seconds(PoolRegistry.minimumShrinkInterval)
    }
    
    private func updateLastShrinkTime() {
        throttleLock.lock()
        defer { throttleLock.unlock() }
        lastShrinkTime = ContinuousClock.now
    }
}

/// Aggregated statistics across all pools
public struct AggregatedPoolStatistics: Sendable {
    public let activePoolCount: Int
    public let totalHits: Int
    public let totalMisses: Int
    public let totalAllocated: Int
    public let totalReused: Int
    public let overallHitRate: Double
    public let overallEfficiency: Double
}

#if DEBUG
/// Detailed per-pool statistics (debug only)
public struct PoolDetailedStatistics: Sendable {
    public let name: String
    public let id: ObjectIdentifier
    public let stats: ObjectPoolStatistics
    public let createdAt: Date
}
#endif
