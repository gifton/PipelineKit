import Foundation

/// Centralized performance threshold configuration for observability
public struct PerformanceThresholds: Sendable {
    /// Threshold for detecting slow command execution
    public let slowCommandThreshold: TimeInterval
    
    /// Threshold for detecting slow middleware execution
    public let slowMiddlewareThreshold: TimeInterval
    
    /// Threshold for excessive memory usage (in MB)
    public let memoryUsageThreshold: Int
    
    /// Default thresholds optimized for typical production workloads
    public static let `default` = PerformanceThresholds(
        slowCommandThreshold: 1.0,
        slowMiddlewareThreshold: 0.01,  // 10ms - more appropriate for middleware
        memoryUsageThreshold: 100
    )
    
    /// Strict thresholds for high-performance environments
    public static let strict = PerformanceThresholds(
        slowCommandThreshold: 0.1,      // 100ms
        slowMiddlewareThreshold: 0.001, // 1ms
        memoryUsageThreshold: 50
    )
    
    /// Relaxed thresholds for development/debugging
    public static let development = PerformanceThresholds(
        slowCommandThreshold: 5.0,
        slowMiddlewareThreshold: 0.1,   // 100ms
        memoryUsageThreshold: 500
    )
    
    /// High-throughput optimized thresholds
    public static let highThroughput = PerformanceThresholds(
        slowCommandThreshold: 0.05,     // 50ms
        slowMiddlewareThreshold: 0.005, // 5ms
        memoryUsageThreshold: 20
    )
    
    public init(
        slowCommandThreshold: TimeInterval,
        slowMiddlewareThreshold: TimeInterval,
        memoryUsageThreshold: Int
    ) {
        self.slowCommandThreshold = slowCommandThreshold
        self.slowMiddlewareThreshold = slowMiddlewareThreshold
        self.memoryUsageThreshold = memoryUsageThreshold
    }
}

/// Global performance threshold configuration
public enum PerformanceConfiguration {
    /// The current global performance thresholds
    /// Using nonisolated(unsafe) to suppress Swift 6 concurrency warning
    /// This is safe because configuration is typically done at app startup
    nonisolated(unsafe) public static var thresholds: PerformanceThresholds = .default
    
    /// Configure performance thresholds based on environment
    public static func configure(for environment: Environment) {
        switch environment {
        case .development:
            thresholds = .development
        case .production:
            thresholds = .default
        case .highPerformance:
            thresholds = .strict
        case .custom(let custom):
            thresholds = custom
        }
    }
    
    /// Environment types for automatic configuration
    public enum Environment {
        case development
        case production
        case highPerformance
        case custom(PerformanceThresholds)
    }
}
