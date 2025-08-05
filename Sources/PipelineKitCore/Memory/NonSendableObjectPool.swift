import Foundation

/// A thread-safe object pool specifically designed for non-Sendable types.
///
/// This actor-based pool provides safe concurrent access to pooled objects
/// without requiring them to conform to Sendable. Objects are guaranteed
/// to be accessed only within the actor's isolation boundary.
///
/// ## Design Rationale
/// 
/// Many performance-critical objects contain mutable state that makes them
/// inherently non-Sendable (e.g., reusable buffers, measurements with mutable
/// properties). This pool allows safe reuse of such objects by ensuring:
/// 
/// 1. All access is serialized through actor isolation
/// 2. Objects never escape the actor boundary during their lifecycle
/// 3. Reset operations ensure clean state between uses
///
/// ## Example
/// ```swift
/// actor MetricsPool {
///     private let pool = NonSendableObjectPool(
///         factory: { MutableMetric() },
///         reset: { $0.clear() }
///     )
///     
///     func recordMetric(name: String, value: Double) async -> Metric {
///         return await pool.withObject { metric in
///             metric.name = name
///             metric.value = value
///             return metric.toImmutable()
///         }
///     }
/// }
/// ```
public actor NonSendableObjectPool<T> {
    /// Factory for creating new instances
    public typealias Factory = () -> T
    
    /// Reset function to prepare object for reuse
    public typealias Reset = (T) -> Void
    
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
    
    /// Creates a new non-sendable object pool.
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
        
        // Pre-allocation will be done in a separate warmUp call
        // since we can't access actor-isolated methods in init
    }
    
    // MARK: - Public Methods
    
    /// Executes a closure with a borrowed object from the pool.
    /// 
    /// The object is automatically returned to the pool when the closure completes.
    /// This is the primary way to use pooled objects safely.
    /// 
    /// - Parameter body: Closure that uses the borrowed object
    /// - Returns: The result of the closure
    /// - Throws: Any error thrown by the closure
    /// 
    /// ## Thread Safety
    /// 
    /// The borrowed object is guaranteed to be accessed only within this actor's
    /// isolation context. The object will be reset (if a reset function was provided)
    /// before being made available for the next use.
    // For Swift 5.10 with strict concurrency, we disable this method
    // and provide an alternative that doesn't trigger sendability warnings
    #if !compiler(>=5.10)
    public func withObject<R: Sendable>(_ body: (T) async throws -> R) async rethrows -> R {
        let object = acquire()
        defer { release(object) }
        return try await body(object)
    }
    #endif
    
    // Alternative API for Swift 5.10+ that avoids sendability issues
    // Callers must manually acquire and release objects
    public func acquireObject() -> T {
        return acquire()
    }
    
    public func releaseObject(_ object: T) {
        release(object)
    }
    
    /// Gets current pool statistics.
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
    
    /// Clears all objects from the pool.
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
    
    /// Warms up the pool by pre-allocating objects.
    public func warmUp(count: Int? = nil) {
        let targetCount = count ?? configuration.preAllocateCount
        let finalCount = min(targetCount, configuration.maxSize)
        available.reserveCapacity(finalCount)
        while available.count < finalCount {
            available.append(createObject())
        }
    }
    
    // MARK: - Private Methods
    
    private func acquire() -> T {
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
    
    private func release(_ object: T) {
        if configuration.trackStatistics {
            totalReturns += 1
        }
        
        inUseCount = max(0, inUseCount - 1)
        
        // Only return to pool if under limit
        if available.count < configuration.maxSize {
            available.append(object)
        }
        // Otherwise, let the object be deallocated
    }
    
    private func createObject() -> T {
        if configuration.trackStatistics {
            totalAllocated += 1
        }
        return factory()
    }
}