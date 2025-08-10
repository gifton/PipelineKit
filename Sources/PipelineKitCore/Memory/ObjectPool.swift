import Foundation

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

    // MARK: - Initialization

    /// Creates a new object pool.
    ///
    /// - Parameters:
    ///   - configuration: Pool configuration settings
    ///   - factory: Closure to create new instances when needed
    ///   - reset: Closure to reset objects before reuse (default: no-op)
    public init(
        configuration: ObjectPoolConfiguration = .default,
        factory: @escaping @Sendable () -> T,
        reset: @escaping @Sendable (T) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.factory = factory
        self.reset = reset
        self.stats = MutablePoolStatistics()

        // Reserve capacity for better performance
        self.available.reserveCapacity(configuration.maxSize)
    }

    // MARK: - Public Methods

    /// Acquires an object from the pool.
    ///
    /// If an object is available in the pool, it will be reset and returned.
    /// Otherwise, a new object is created using the factory closure.
    ///
    /// - Returns: An object ready for use
    public func acquire() -> T {
        let object: T
        let wasHit: Bool

        if let pooled = available.popLast() {
            // Reuse from pool
            reset(pooled)
            object = pooled
            wasHit = true
        } else {
            // Create new
            object = factory()
            wasHit = false
        }

        if configuration.trackStatistics {
            stats.recordAcquisition(wasHit: wasHit)
        }

        return object
    }

    /// Releases an object back to the pool.
    ///
    /// The object will be stored for reuse if the pool hasn't reached
    /// its maximum size. Otherwise, it will be discarded.
    ///
    /// - Parameter object: The object to return to the pool
    public func release(_ object: T) {
        let wasEvicted: Bool

        if available.count < configuration.maxSize {
            // Return to pool
            available.append(object)
            wasEvicted = false
        } else {
            // Pool is full, discard
            wasEvicted = true
        }

        if configuration.trackStatistics {
            stats.recordRelease(wasEvicted: wasEvicted)
        }
    }

    /// Gets current pool statistics.
    ///
    /// - Returns: A snapshot of current statistics, or empty if tracking is disabled
    public func statistics() -> ObjectPoolStatistics {
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
    /// - Parameter targetSize: Target number of objects to keep
    public func shrink(to targetSize: Int) {
        guard available.count > targetSize else { return }

        let toRemove = available.count - targetSize
        available.removeLast(toRemove)

        if configuration.trackStatistics {
            stats.evictions += toRemove
            stats.currentlyAvailable = available.count
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
            configuration: ObjectPoolConfiguration(maxSize: maxSize),
            factory: factory
        )
    }
}
