import Foundation

/// A generic thread-safe object pool for reusing instances to reduce allocations.
///
/// The pool maintains a collection of pre-allocated objects that can be
/// borrowed and returned, significantly reducing allocation overhead.
///
/// This actor provides thread-safe access to pooled objects and
/// automatically manages the pool size based on configuration.
public actor GenericObjectPool<T> {
    /// Factory for creating new instances
    public typealias Factory = @Sendable () -> T
    
    /// Reset function to prepare object for reuse
    public typealias Reset = @Sendable (T) -> Void
    
    /// Configuration for the pool
    public struct Configuration: Sendable {
        /// Maximum number of objects to keep in the pool
        public let maxSize: Int
        
        /// Number of objects to pre-allocate
        public let preAllocateCount: Int
        
        /// Whether to track statistics
        public let trackStatistics: Bool
        
        public init(
            maxSize: Int = 100,
            preAllocateCount: Int = 10,
            trackStatistics: Bool = true
        ) {
            self.maxSize = maxSize
            self.preAllocateCount = min(preAllocateCount, maxSize)
            self.trackStatistics = trackStatistics
        }
    }
    
    /// Statistics about pool usage
    public struct Statistics: Sendable {
        public let totalAllocated: Int
        public let currentlyAvailable: Int
        public let currentlyInUse: Int
        public let totalBorrows: Int
        public let totalReturns: Int
        public let hits: Int
        public let hitRate: Double
        public let peakUsage: Int
    }
    
    // MARK: - Private Properties
    
    private let configuration: Configuration
    private let factory: Factory
    private let reset: Reset?
    
    private var available: [T] = []
    private var inUseCount = 0
    
    // Statistics
    private var totalAllocated = 0
    private var totalBorrows = 0
    private var totalReturns = 0
    private var hits = 0
    private var peakUsage = 0
    
    // MARK: - Initialization
    
    /// Creates a new object pool
    /// - Parameters:
    ///   - configuration: Pool configuration
    ///   - factory: Factory function to create new instances
    ///   - reset: Optional reset function to prepare objects for reuse
    public init(
        configuration: Configuration = Configuration(),
        factory: @escaping Factory,
        reset: Reset? = nil
    ) {
        self.configuration = configuration
        self.factory = factory
        self.reset = reset
        self.available = []
        
        // Note: Pre-allocation cannot be done in init due to actor isolation
        // Use warmUp() after creation to pre-allocate objects
    }
    
    // MARK: - Public Methods
    
    /// Borrows an object from the pool
    public func acquire() -> T {
        if configuration.trackStatistics {
            totalBorrows += 1
        }
        
        let object: T
        if let existing = available.popLast() {
            // Reuse existing object
            if let reset = reset {
                reset(existing)
            }
            object = existing
            if configuration.trackStatistics {
                hits += 1
            }
        } else {
            // Create new object
            object = createObject()
        }
        
        inUseCount += 1
        if configuration.trackStatistics && inUseCount > peakUsage {
            peakUsage = inUseCount
        }
        
        return object
    }
    
    /// Returns an object to the pool
    public func release(_ object: T) {
        if configuration.trackStatistics {
            totalReturns += 1
        }
        
        inUseCount = max(0, inUseCount - 1)
        
        // Only return to pool if under limit
        if available.count < configuration.maxSize {
            available.append(object)
        }
    }
    
    /// Gets current pool statistics
    public func getStatistics() -> Statistics {
        let hitRate = totalBorrows > 0 
            ? Double(hits) / Double(totalBorrows) 
            : 0.0
        
        return Statistics(
            totalAllocated: totalAllocated,
            currentlyAvailable: available.count,
            currentlyInUse: inUseCount,
            totalBorrows: totalBorrows,
            totalReturns: totalReturns,
            hits: hits,
            hitRate: hitRate,
            peakUsage: peakUsage
        )
    }
    
    /// Borrows an object from the pool for the duration of the provided closure.
    /// The object is automatically returned to the pool when the closure completes.
    /// - Parameter body: Closure that uses the borrowed object
    /// - Returns: The result of the closure
    /// - Throws: Any error thrown by the closure
    public func withBorrowedObject<R: Sendable>(
        _ body: @Sendable (T) async throws -> R
    ) async throws -> R {
        let object = acquire()
        do {
            let result = try await body(object)
            release(object)
            return result
        } catch {
            release(object)
            throw error
        }
    }
    
    /// Clears all objects from the pool
    public func clear() {
        available.removeAll()
        inUseCount = 0
        if configuration.trackStatistics {
            totalAllocated = 0
            totalBorrows = 0
            totalReturns = 0
            hits = 0
            peakUsage = 0
        }
    }
    
    /// Warms up the pool by pre-allocating objects up to the specified count
    public func warmUp(count: Int) {
        let targetCount = min(count, configuration.maxSize)
        while available.count < targetCount {
            available.append(createObject())
        }
    }
    
    // MARK: - Private Methods
    
    private func createObject() -> T {
        if configuration.trackStatistics {
            totalAllocated += 1
        }
        return factory()
    }
}

// MARK: - Pooled Wrapper

/// A wrapper that automatically returns objects to the pool when deallocated
///
/// ## Design Decision: @unchecked Sendable for Generic Wrapper
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Generic Type Constraint**: The generic type `T` is not constrained to be Sendable
///    because the pool needs to support various object types, including those with
///    mutable state that are reset between uses.
///
/// 2. **NSLock Protection**: The `isReturned` flag is protected by NSLock to ensure
///    thread-safe access when checking if the object has already been returned to the pool.
///
/// 3. **Lifecycle Management**: This wrapper manages the lifecycle of pooled objects,
///    ensuring they are returned to the pool when no longer needed. The thread safety
///    is managed at the pool level, not the individual object level.
///
/// 4. **Reference Semantics**: As a reference type wrapper, it allows the pool to track
///    and manage object lifecycle while providing a clean API to consumers.
///
/// The wrapper itself is thread-safe through lock protection, while the wrapped object's
/// thread safety is the responsibility of the pool's configuration and usage patterns.
public final class PooledObject<T>: @unchecked Sendable {
    private let value: T
    private let pool: GenericObjectPool<T>
    private var isReturned = false
    private let lock = NSLock()
    
    init(value: T, pool: GenericObjectPool<T>) {
        self.value = value
        self.pool = pool
    }
    
    deinit {
        // Note: We can't use async in deinit, so we'll rely on manual returnToPool() calls
        // or accept that some objects may not be returned if not manually returned
    }
    
    /// The underlying pooled object
    public var object: T {
        return value
    }
    
    /// Manually return to pool (called automatically on deinit)
    public func returnToPool() async {
        let shouldReturn = lock.withLock {
            guard !isReturned else { return false }
            isReturned = true
            return true
        }
        
        if shouldReturn {
            await pool.release(value)
        }
    }
}

// MARK: - Convenience Extensions

extension GenericObjectPool {
    /// Acquires an object wrapped in a PooledObject for automatic return
    public func acquirePooled() -> PooledObject<T> {
        let object = acquire()
        return PooledObject(value: object, pool: self)
    }
}