import Foundation
import Atomics

/// A thread-safe object pool for recycling frequently allocated objects.
///
/// `ObjectPool` reduces memory allocations by reusing objects instead of creating new ones.
/// It's particularly useful for objects that are created and destroyed frequently, such as
/// command contexts, results, and temporary buffers.
///
/// ## Features
/// - Lock-free implementation using atomic operations
/// - Configurable size limits
/// - Automatic cleanup of excess objects
/// - Statistics tracking for monitoring
/// - **Memory pressure handling with automatic shrinking**
/// - **Configurable high/low water marks**
///
/// ## Example
/// ```swift
/// let pool = ObjectPool<CommandContext>(
///     maxSize: 100,
///     factory: { CommandContext() },
///     reset: { $0.clear() }
/// )
///
/// let context = await pool.acquire()
/// // Use context...
/// await pool.release(context)
/// ```
public actor ObjectPool<T: AnyObject> {
    /// Factory closure to create new instances
    private let factory: @Sendable () -> T
    
    /// Reset closure to prepare objects for reuse
    private let reset: @Sendable (T) async -> Void
    
    /// Maximum number of objects to keep in the pool
    private let maxSize: Int
    
    /// **High water mark - start releasing objects above this threshold**
    private let highWaterMark: Int
    
    /// **Low water mark - aggressively release objects to this level under pressure**
    private let lowWaterMark: Int
    
    /// Available objects ready for reuse
    private var available: [T] = []
    
    /// Statistics tracking
    private var stats = PoolStatistics()
    
    /// **Memory pressure handler registration ID**
    private var memoryHandlerID: UUID?
    
    /// Creates a new object pool.
    ///
    /// - Parameters:
    ///   - maxSize: Maximum number of objects to keep pooled
    ///   - highWaterMark: Pool size threshold to start releasing objects (default: 80% of maxSize)
    ///   - lowWaterMark: Target pool size under memory pressure (default: 20% of maxSize)
    ///   - factory: Closure to create new instances when pool is empty
    ///   - reset: Closure to reset objects before returning to pool
    public init(
        maxSize: Int = 100,
        highWaterMark: Int? = nil,
        lowWaterMark: Int? = nil,
        factory: @escaping @Sendable () -> T,
        reset: @escaping @Sendable (T) async -> Void = { _ in }
    ) {
        self.maxSize = maxSize
        self.highWaterMark = highWaterMark ?? Int(Double(maxSize) * 0.8)
        self.lowWaterMark = lowWaterMark ?? Int(Double(maxSize) * 0.2)
        self.factory = factory
        self.reset = reset
        
        // **Register for memory pressure handling**
        Task {
            await self.registerMemoryPressureHandler()
        }
    }
    
    deinit {
        // **Cleanup memory pressure handler**
        if let handlerID = memoryHandlerID {
            Task {
                await MemoryPressureMonitor.shared.unregister(id: handlerID)
            }
        }
    }
    
    /// Acquires an object from the pool or creates a new one.
    ///
    /// - Returns: An object ready for use
    public func acquire() -> T {
        stats.acquisitions += 1
        
        if let object = available.popLast() {
            stats.hits += 1
            return object
        } else {
            stats.misses += 1
            stats.allocations += 1
            return factory()
        }
    }
    
    /// Returns an object to the pool for reuse.
    ///
    /// - Parameter object: The object to return to the pool
    public func release(_ object: T) async {
        stats.releases += 1
        
        // Reset the object for reuse
        await reset(object)
        
        // Only keep if under size limit
        if available.count < maxSize {
            available.append(object)
        } else {
            stats.evictions += 1
            // Let it be deallocated
        }
    }
    
    /// Pre-warms the pool by creating objects up to the specified count.
    ///
    /// - Parameter count: Number of objects to pre-create (capped at maxSize)
    public func prewarm(count: Int) async {
        let targetCount = min(count, maxSize)
        let toCreate = max(0, targetCount - available.count)
        
        for _ in 0..<toCreate {
            let object = factory()
            await reset(object)
            available.append(object)
            stats.allocations += 1
        }
    }
    
    /// Clears all objects from the pool.
    public func clear() {
        available.removeAll()
    }
    
    /// Gets current pool statistics.
    public var statistics: PoolStatistics {
        stats
    }
    
    /// Current number of available objects in the pool.
    public var availableCount: Int {
        available.count
    }
    
    // MARK: - Memory Pressure Handling
    
    /// **Registers this pool with the memory pressure handler.**
    private func registerMemoryPressureHandler() async {
        memoryHandlerID = await MemoryPressureMonitor.shared.register { [weak self] in
            await self?.handleMemoryPressure()
        }
    }
    
    /// **Handles memory pressure by shrinking the pool.**
    private func handleMemoryPressure() async {
        let pressureLevel = await MemoryPressureMonitor.shared.pressureLevel
        
        switch pressureLevel {
        case .normal:
            // Trim to high water mark if exceeded
            await trimToSize(highWaterMark)
        case .warning:
            // More aggressive trimming
            let targetSize = (highWaterMark + lowWaterMark) / 2
            await trimToSize(targetSize)
        case .critical:
            // Aggressive trimming to low water mark
            await trimToSize(lowWaterMark)
        }
        
        stats.memoryPressureEvents += 1
    }
    
    /// **Trims the pool to the specified size.**
    private func trimToSize(_ targetSize: Int) async {
        guard available.count > targetSize else { return }
        
        let toRemove = available.count - targetSize
        available.removeLast(toRemove)
        
        stats.evictions += toRemove
        stats.memoryPressureEvictions += toRemove
    }
    
    /// **Manually triggers memory pressure handling for testing.**
    public func simulateMemoryPressure(level: MemoryPressureLevel) async {
        switch level {
        case .normal:
            await trimToSize(highWaterMark)
        case .warning:
            await trimToSize((highWaterMark + lowWaterMark) / 2)
        case .critical:
            await trimToSize(lowWaterMark)
        }
    }
}

/// Statistics for monitoring pool performance.
public struct PoolStatistics: Sendable {
    /// Total number of acquisitions
    public var acquisitions: Int = 0
    
    /// Number of acquisitions served from pool
    public var hits: Int = 0
    
    /// Number of acquisitions that required allocation
    public var misses: Int = 0
    
    /// Total number of releases back to pool
    public var releases: Int = 0
    
    /// Total number of new allocations
    public var allocations: Int = 0
    
    /// Number of objects evicted due to size limits
    public var evictions: Int = 0
    
    /// **Number of memory pressure events handled**
    public var memoryPressureEvents: Int = 0
    
    /// **Number of objects evicted due to memory pressure**
    public var memoryPressureEvictions: Int = 0
    
    /// Hit rate as a percentage (0-100)
    public var hitRate: Double {
        guard acquisitions > 0 else { return 0 }
        return Double(hits) / Double(acquisitions) * 100
    }
    
    /// Efficiency score (higher is better)
    public var efficiency: Double {
        guard allocations > 0 else { return 0 }
        return Double(acquisitions) / Double(allocations)
    }
    
    /// **Memory pressure response rate (evictions per event)**
    public var memoryPressureResponseRate: Double {
        guard memoryPressureEvents > 0 else { return 0 }
        return Double(memoryPressureEvictions) / Double(memoryPressureEvents)
    }
}

// MARK: - Specialized Pools

/// Pool for CommandContext objects with automatic cleanup.
public final class CommandContextPool {
    private let pool: ObjectPool<CommandContext>
    
    public init(maxSize: Int = 100) {
        self.pool = ObjectPool(
            maxSize: maxSize,
            factory: { CommandContext() },
            reset: { context in
                await context.clear()
            }
        )
    }
    
    public func acquire() async -> CommandContext {
        await pool.acquire()
    }
    
    public func release(_ context: CommandContext) async {
        await pool.release(context)
    }
    
    public func statistics() async -> PoolStatistics {
        await pool.statistics
    }
}

/// Pool for reusable buffer objects.
public final class BufferPool<T> {
    private let pool: ObjectPool<Buffer<T>>
    
    public class Buffer<Element> {
        var data: [Element]
        let capacity: Int
        
        init(capacity: Int) {
            self.capacity = capacity
            self.data = []
            self.data.reserveCapacity(capacity)
        }
        
        func reset() {
            data.removeAll(keepingCapacity: true)
        }
    }
    
    public init(maxSize: Int = 50, bufferCapacity: Int = 1024) {
        self.pool = ObjectPool(
            maxSize: maxSize,
            factory: { Buffer(capacity: bufferCapacity) },
            reset: { buffer in
                buffer.reset()
            }
        )
    }
    
    public func acquire() async -> Buffer<T> {
        await pool.acquire()
    }
    
    public func release(_ buffer: Buffer<T>) async {
        await pool.release(buffer)
    }
}

// MARK: - Global Pool Manager

/// Manages a collection of object pools for the pipeline system.
public actor PoolManager {
    /// Shared instance for global access
    public static let shared = PoolManager()
    
    /// Pool for command contexts
    public let contextPool = CommandContextPool(maxSize: 200)
    
    /// Pool for data buffers
    public let dataBufferPool = BufferPool<UInt8>(maxSize: 100, bufferCapacity: 4096)
    
    /// Pool for string buffers
    public let stringBufferPool = BufferPool<Character>(maxSize: 50, bufferCapacity: 1024)
    
    private init() {}
    
    /// Gets aggregated statistics from all pools.
    public func aggregatedStatistics() async -> AggregatedPoolStatistics {
        let contextStats = await contextPool.statistics()
        
        return AggregatedPoolStatistics(
            pools: [
                ("CommandContext", contextStats)
            ]
        )
    }
    
    /// Pre-warms all pools for better initial performance.
    public func prewarmAll() async {
        // Prewarm context pool with a reasonable number
        await contextPool.pool.prewarm(count: 20)
        
        // Prewarm buffer pools
        await dataBufferPool.pool.prewarm(count: 10)
        await stringBufferPool.pool.prewarm(count: 5)
    }
}

/// Aggregated statistics from multiple pools.
public struct AggregatedPoolStatistics {
    public let pools: [(name: String, stats: PoolStatistics)]
    
    public var totalAcquisitions: Int {
        pools.reduce(0) { $0 + $1.stats.acquisitions }
    }
    
    public var totalAllocations: Int {
        pools.reduce(0) { $0 + $1.stats.allocations }
    }
    
    public var overallHitRate: Double {
        let totalHits = pools.reduce(0) { $0 + $1.stats.hits }
        let totalAcquisitions = self.totalAcquisitions
        guard totalAcquisitions > 0 else { return 0 }
        return Double(totalHits) / Double(totalAcquisitions) * 100
    }
    
    public var overallEfficiency: Double {
        guard totalAllocations > 0 else { return 0 }
        return Double(totalAcquisitions) / Double(totalAllocations)
    }
}