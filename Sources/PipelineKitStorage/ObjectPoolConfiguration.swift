import Foundation

/// Errors that can occur when creating an ObjectPoolConfiguration.
public enum ObjectPoolConfigurationError: Error, LocalizedError {
    case invalidMaxSize(Int)
    case invalidWatermarks(low: Int, high: Int, max: Int)
    
    public var errorDescription: String? {
        switch self {
        case .invalidMaxSize(let size):
            return "ObjectPoolConfiguration: maxSize must be positive, got \(size)"
        case .invalidWatermarks(let low, let high, let max):
            return "ObjectPoolConfiguration: invalid watermarks (low: \(low), high: \(high), max: \(max))"
        }
    }
}

/// Configuration for object pools.
///
/// This configuration is shared across all pool types and provides
/// common settings for pool behavior, size limits, and features.
///
/// ## Example
/// ```swift
/// let config = try ObjectPoolConfiguration(
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
    /// - Throws: `ObjectPoolConfigurationError` if parameters are invalid
    public init(
        maxSize: Int = 100,
        highWaterMark: Int? = nil,
        lowWaterMark: Int? = nil,
        trackStatistics: Bool = true,
        enableMemoryPressureHandling: Bool = true
    ) throws {
        // Validate configuration before assignment
        guard maxSize > 0 else {
            throw ObjectPoolConfigurationError.invalidMaxSize(maxSize)
        }
        
        let calculatedHighWaterMark = highWaterMark ?? Int(Double(maxSize) * 0.8)
        let calculatedLowWaterMark = lowWaterMark ?? Int(Double(maxSize) * 0.2)
        
        // Validate watermarks
        guard calculatedHighWaterMark <= maxSize,
              calculatedLowWaterMark <= calculatedHighWaterMark,
              calculatedLowWaterMark >= 0 else {
            throw ObjectPoolConfigurationError.invalidWatermarks(
                low: calculatedLowWaterMark,
                high: calculatedHighWaterMark,
                max: maxSize
            )
        }
        
        self.maxSize = maxSize
        self.highWaterMark = calculatedHighWaterMark
        self.lowWaterMark = calculatedLowWaterMark
        self.trackStatistics = trackStatistics
        self.enableMemoryPressureHandling = enableMemoryPressureHandling
    }

    /// Default configuration with reasonable settings.
    public static let `default` = try! ObjectPoolConfiguration()

    /// Small pool configuration (maxSize: 10).
    public static let small = try! ObjectPoolConfiguration(maxSize: 10)

    /// Large pool configuration (maxSize: 1000).
    public static let large = try! ObjectPoolConfiguration(maxSize: 1000)

    /// Performance-optimized configuration with statistics disabled.
    public static let performance = try! ObjectPoolConfiguration(
        maxSize: 100,
        trackStatistics: false
    )
}
