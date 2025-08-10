import Foundation

/// Configuration for object pools.
///
/// This configuration is shared across all pool types and provides
/// common settings for pool behavior, size limits, and features.
///
/// ## Example
/// ```swift
/// let config = ObjectPoolConfiguration(
///     maxSize: 100,
///     highWaterMark: 80,
///     lowWaterMark: 20
/// )
/// let pool = ObjectPool(configuration: config, factory: { MyObject() })
/// ```
public struct ObjectPoolConfiguration: Sendable {
    /// Maximum number of objects to keep in the pool.
    public let maxSize: Int

    /// High water mark for reference type pools.
    ///
    /// When the pool size exceeds this threshold, it may start
    /// releasing objects more aggressively.
    public let highWaterMark: Int

    /// Low water mark for reference type pools.
    ///
    /// Under memory pressure, the pool will shrink to this size.
    public let lowWaterMark: Int

    /// Whether to track detailed statistics.
    public let trackStatistics: Bool

    /// Whether to enable memory pressure handling (iOS/macOS only).
    ///
    /// This enables memory pressure handling for reference type pools.
    public let enableMemoryPressureHandling: Bool

    /// Creates a pool configuration with the specified settings.
    ///
    /// - Parameters:
    ///   - maxSize: Maximum number of objects to pool (default: 100)
    ///   - highWaterMark: High water mark percentage (default: 80% of maxSize)
    ///   - lowWaterMark: Low water mark percentage (default: 20% of maxSize)
    ///   - trackStatistics: Whether to track statistics (default: true)
    ///   - enableMemoryPressureHandling: Whether to respond to memory pressure (default: true)
    public init(
        maxSize: Int = 100,
        highWaterMark: Int? = nil,
        lowWaterMark: Int? = nil,
        trackStatistics: Bool = true,
        enableMemoryPressureHandling: Bool = true
    ) {
        self.maxSize = maxSize
        self.highWaterMark = highWaterMark ?? Int(Double(maxSize) * 0.8)
        self.lowWaterMark = lowWaterMark ?? Int(Double(maxSize) * 0.2)
        self.trackStatistics = trackStatistics
        self.enableMemoryPressureHandling = enableMemoryPressureHandling

        // Validate configuration
        assert(maxSize > 0, "Pool size must be positive")
        assert(self.highWaterMark <= maxSize, "High water mark must not exceed max size")
        assert(self.lowWaterMark <= self.highWaterMark, "Low water mark must not exceed high water mark")
        assert(self.lowWaterMark >= 0, "Low water mark must be non-negative")
    }

    /// Default configuration with reasonable settings.
    public static let `default` = ObjectPoolConfiguration()

    /// Small pool configuration (maxSize: 10).
    public static let small = ObjectPoolConfiguration(maxSize: 10)

    /// Large pool configuration (maxSize: 1000).
    public static let large = ObjectPoolConfiguration(maxSize: 1000)

    /// Performance-optimized configuration with statistics disabled.
    public static let performance = ObjectPoolConfiguration(
        maxSize: 100,
        trackStatistics: false
    )
}
