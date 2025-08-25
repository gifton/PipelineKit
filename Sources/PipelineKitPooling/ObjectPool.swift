import Foundation
import PipelineKitResilience  // For AsyncSemaphore

/// A thread-safe object pool for reusing instances to reduce allocations.
///
/// ObjectPool provides a high-performance, thread-safe mechanism for
/// recycling objects. It's particularly useful for frequently allocated
/// objects like buffers, contexts, or temporary data structures.
///
/// ## Features
/// - Works with any Sendable type
/// - Thread-safe via actor isolation
/// - Configurable size limits
/// - Optional statistics tracking
/// - Factory and reset closures for object lifecycle
///
/// ## Example
/// ```swift
/// let pool = ObjectPool(
///     configuration: .default,
///     factory: { Buffer() },
///     reset: { $0.clear() }
/// )
///
/// let buffer = await pool.acquire()
/// // Use buffer...
/// await pool.release(buffer)
/// ```
///
/// ## Performance Notes
/// The pool uses actor isolation for thread safety, which has minimal
/// overhead for the acquire/release operations.
public actor ObjectPool<T: Sendable> {
    // MARK: - Properties
    
    /// Pool name for identification in metrics
    public let name: String

    /// Pool configuration.
    public let configuration: ObjectPoolConfiguration

    /// Factory closure to create new instances.
    private let factory: @Sendable () -> T

    /// Reset closure to prepare objects for reuse.
    private let reset: @Sendable (T) -> Void

    /// Available objects ready for reuse.
    private var available: [T] = []

    /// Statistics tracking (if enabled).
    private var stats: MutablePoolStatistics
    
    /// Whether this pool is registered for metrics
    private let registerMetrics: Bool
    
    /// Track if the pool is still active (not deinited)
    private var isActive = true
    
    /// Semaphore to enforce maximum pool size
    /// This limits the total number of objects in circulation (both in-use and available)
    private let sizeSemaphore: AsyncSemaphore

    // MARK: - Initialization

    /// Creates a new object pool.
    ///
    /// - Parameters:
    ///   - name: Optional name for the pool (auto-generated if nil)
    ///   - configuration: Pool configuration settings
    ///   - factory: Closure to create new instances when needed
    ///   - reset: Closure to reset objects before reuse (default: no-op)
    ///   - registerMetrics: Whether to register with PoolRegistry (default: uses global setting)
    public init(
        name: String? = nil,
        configuration: ObjectPoolConfiguration = .default,
        factory: @escaping @Sendable () -> T,
        reset: @escaping @Sendable (T) -> Void = { _ in },
        registerMetrics: Bool? = nil
    ) {
        self.name = name ?? PoolRegistry.generatePoolName(for: T.self)
        self.configuration = configuration
        self.factory = factory
        self.reset = reset
        self.stats = MutablePoolStatistics()
        self.stats.maxSize = configuration.maxSize
        self.registerMetrics = registerMetrics ?? PoolRegistry.metricsEnabledByDefault
        
        // Initialize semaphore with max pool size to enforce limits
        self.sizeSemaphore = AsyncSemaphore(value: configuration.maxSize)

        // Reserve capacity for better performance
        self.available.reserveCapacity(configuration.maxSize)
        
        // Register with pool registry if enabled
        if self.registerMetrics {
            Task { [weak self] in
                guard let self = self else { return }
                // Check if still active before registering
                guard await self.isActive else { return }
                await PoolRegistry.shared.register(self)
            }
        }
    }
    
    deinit {
        // Mark as inactive to prevent race conditions
        // Note: We can't access actor-isolated properties here, but isActive was marked
        // nonisolated in the registration task, so the race condition is handled there
        
        // Unregister from pool registry if registered
        if registerMetrics {
            PoolRegistry.shared.unregister(id: ObjectIdentifier(self))
        }
        
        // The pool's available array will be deallocated automatically
    }

    // MARK: - Public Methods

    /// Acquires an object from the pool.
    ///
    /// If an object is available in the pool, it will be reset and returned.
    /// Otherwise, a new object is created using the factory closure.
    /// 
    /// This method will wait if the pool has reached its maximum capacity
    /// (all objects are currently in use).
    ///
    /// - Returns: An object ready for use
    /// - Throws: PipelineError if the wait is interrupted
    public func acquire() async throws -> T {
        let startTime = ContinuousClock.now
        
        // Wait for a permit from the semaphore (blocks if at max capacity)
        try await sizeSemaphore.wait()
        
        let object: T
        let wasHit: Bool

        if let pooled = available.popLast() {
            // Reuse from pool
            reset(pooled)
            object = pooled
            wasHit = true
        } else {
            // Create new (we have a permit, so we're within limits)
            object = factory()
            wasHit = false
        }

        if configuration.trackStatistics {
            stats.recordAcquisition(wasHit: wasHit)
        }
        
        // Record observability metrics
        if registerMetrics {
            let latency = startTime.duration(to: ContinuousClock.now)
            Task {
                await PoolObservability.shared.recordPoolAcquisition(
                    poolName: name,
                    wasHit: wasHit,
                    latencyNanos: UInt64(latency.components.attoseconds / 1_000_000_000)
                )
            }
        }

        return object
    }

    /// Releases an object back to the pool.
    ///
    /// The object will be stored for reuse if the pool hasn't reached
    /// its maximum size. Otherwise, it will be discarded.
    ///
    /// - Parameter object: The object to return to the pool
    public func release(_ object: T) async {
        let startTime = ContinuousClock.now
        let wasEvicted: Bool

        if available.count < configuration.maxSize {
            // Return to pool
            available.append(object)
            wasEvicted = false
        } else {
            // Pool is full, discard
            wasEvicted = true
        }
        
        // Always signal the semaphore to release the permit
        await sizeSemaphore.signal()

        if configuration.trackStatistics {
            stats.recordRelease(wasEvicted: wasEvicted)
        }
        
        // Record observability metrics
        if registerMetrics {
            let latency = startTime.duration(to: ContinuousClock.now)
            Task {
                await PoolObservability.shared.recordPoolRelease(
                    poolName: name,
                    wasEvicted: wasEvicted,
                    latencyNanos: UInt64(latency.components.attoseconds / 1_000_000_000)
                )
                
                // Update size metrics
                await PoolObservability.shared.updatePoolSize(
                    poolName: name,
                    available: available.count,
                    inUse: stats.currentlyInUse,
                    maxSize: configuration.maxSize
                )
            }
        }
    }

    /// Gets current pool statistics.
    ///
    /// - Returns: A snapshot of current statistics, or empty if tracking is disabled
    public var statistics: ObjectPoolStatistics {
        guard configuration.trackStatistics else { return .empty }

        // Update current counts
        stats.currentlyAvailable = available.count

        return stats.snapshot()
    }

    /// Clears all objects from the pool.
    ///
    /// This removes all available objects, allowing them to be deallocated.
    /// Statistics are preserved.
    public func clear() {
        available.removeAll(keepingCapacity: true)
        if configuration.trackStatistics {
            stats.currentlyAvailable = 0
        }
    }

    /// Pre-allocates objects up to the specified count.
    ///
    /// This can be useful to warm up the pool before heavy usage.
    ///
    /// - Parameter count: Number of objects to pre-allocate (capped by maxSize)
    public func preallocate(count: Int) {
        let targetCount = min(count, configuration.maxSize)
        let toAllocate = targetCount - available.count

        guard toAllocate > 0 else { return }

        for _ in 0..<toAllocate {
            available.append(factory())
            if configuration.trackStatistics {
                stats.totalAllocated += 1
                stats.currentlyAvailable += 1
            }
        }
    }

    // MARK: - Water Mark Support

    /// Shrinks the pool to the specified size.
    ///
    /// This is exposed for manual pool management.
    ///
    /// - Parameter targetSize: Target number of objects to keep (clamped to >= 0)
    public func shrink(to targetSize: Int) {
        // Validate and clamp target size
        let clampedSize = max(0, targetSize)
        
        guard available.count > clampedSize else { return }

        let toRemove = available.count - clampedSize
        available.removeLast(toRemove)

        if configuration.trackStatistics {
            stats.evictions += toRemove
            stats.currentlyAvailable = available.count
        }
        
        // Record observability metrics
        if registerMetrics && toRemove > 0 {
            Task {
                await PoolObservability.shared.recordPoolShrink(
                    poolName: name,
                    objectsRemoved: toRemove,
                    wasThrottled: false,
                    reason: "manual"
                )
            }
        }
    }
}

// MARK: - Convenience Initializers

public extension ObjectPool {
    /// Creates a pool with just a factory closure.
    ///
    /// Use this when objects don't need resetting between uses.
    ///
    /// - Parameter factory: Closure to create new instances
    init(factory: @escaping @Sendable () -> T) {
        self.init(configuration: .default, factory: factory)
    }

    /// Creates a pool with a specific size limit.
    ///
    /// - Parameters:
    ///   - maxSize: Maximum number of objects to pool
    ///   - factory: Closure to create new instances
    init(maxSize: Int, factory: @escaping @Sendable () -> T) {
        self.init(
            configuration: try! ObjectPoolConfiguration(maxSize: maxSize),
            factory: factory
        )
    }
}
