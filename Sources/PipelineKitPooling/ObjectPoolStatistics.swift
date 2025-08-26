import Foundation

/// Statistics for object pool usage.
///
/// Tracks various metrics about pool performance and usage patterns
/// to help with optimization and debugging.
public struct ObjectPoolStatistics: Sendable {
    /// Total number of objects allocated by the pool.
    public let totalAllocated: Int

    /// Number of objects currently available in the pool.
    public let currentlyAvailable: Int

    /// Number of objects currently in use (checked out).
    public let currentlyInUse: Int
    
    /// Maximum pool size configured for this pool.
    public let maxSize: Int

    /// Total number of acquire operations.
    public let totalAcquisitions: Int

    /// Total number of release operations.
    public let totalReleases: Int

    /// Number of times an object was reused from the pool.
    public let hits: Int

    /// Number of times a new object had to be created.
    public let misses: Int

    /// Cache hit rate (0.0 to 1.0).
    public var hitRate: Double {
        guard totalAcquisitions > 0 else { return 0.0 }
        return Double(hits) / Double(totalAcquisitions)
    }

    /// Number of objects evicted due to pool size limits.
    public let evictions: Int

    /// Peak number of objects in use at one time.
    public let peakUsage: Int

    /// Average time objects spend in the pool (if tracked).
    public let averagePoolTime: TimeInterval?

    /// Creates a statistics snapshot.
    public init(
        totalAllocated: Int = 0,
        currentlyAvailable: Int = 0,
        currentlyInUse: Int = 0,
        maxSize: Int = 0,
        totalAcquisitions: Int = 0,
        totalReleases: Int = 0,
        hits: Int = 0,
        misses: Int = 0,
        evictions: Int = 0,
        peakUsage: Int = 0,
        averagePoolTime: TimeInterval? = nil
    ) {
        self.totalAllocated = totalAllocated
        self.currentlyAvailable = currentlyAvailable
        self.currentlyInUse = currentlyInUse
        self.maxSize = maxSize
        self.totalAcquisitions = totalAcquisitions
        self.totalReleases = totalReleases
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
        self.peakUsage = peakUsage
        self.averagePoolTime = averagePoolTime
    }

    /// Empty statistics for initial state.
    public static let empty = ObjectPoolStatistics()
}

/// Internal mutable statistics tracker.
///
/// This is used internally by the pool to track statistics
/// efficiently without creating new instances for each update.
struct MutablePoolStatistics {
    var totalAllocated: Int = 0
    var currentlyAvailable: Int = 0
    var currentlyInUse: Int = 0
    var maxSize: Int = 0
    var totalAcquisitions: Int = 0
    var totalReleases: Int = 0
    var hits: Int = 0
    var misses: Int = 0
    var evictions: Int = 0
    var peakUsage: Int = 0

    /// Creates an immutable snapshot of current statistics.
    func snapshot() -> ObjectPoolStatistics {
        ObjectPoolStatistics(
            totalAllocated: totalAllocated,
            currentlyAvailable: currentlyAvailable,
            currentlyInUse: currentlyInUse,
            maxSize: maxSize,
            totalAcquisitions: totalAcquisitions,
            totalReleases: totalReleases,
            hits: hits,
            misses: misses,
            evictions: evictions,
            peakUsage: peakUsage
        )
    }

    /// Records an acquisition (object checked out).
    mutating func recordAcquisition(wasHit: Bool) {
        totalAcquisitions += 1
        currentlyInUse += 1

        if wasHit {
            hits += 1
            currentlyAvailable -= 1
        } else {
            misses += 1
            totalAllocated += 1
        }

        if currentlyInUse > peakUsage {
            peakUsage = currentlyInUse
        }
    }

    /// Records a release (object returned).
    mutating func recordRelease(wasEvicted: Bool) {
        totalReleases += 1
        currentlyInUse -= 1

        if wasEvicted {
            evictions += 1
        } else {
            currentlyAvailable += 1
        }
    }
}
