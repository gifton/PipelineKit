import Foundation

/// Thread-safe configuration for CommandContextPool
/// Uses actor isolation to ensure all configuration changes are synchronized
public actor ContextPoolConfiguration {
    /// Shared configuration instance
    public static let shared = ContextPoolConfiguration()
    
    /// The global pool size (default: 100)
    private var globalPoolSize: Int = 100
    
    /// Whether to use pooling by default
    private var usePoolingByDefault: Bool = true
    
    /// Monitor for pool performance
    private var monitor: ContextPoolMonitor?
    
    // MARK: - Public API
    
    public var poolSize: Int {
        globalPoolSize
    }
    
    public var poolingEnabled: Bool {
        usePoolingByDefault
    }
    
    public var currentMonitor: ContextPoolMonitor? {
        monitor
    }
    
    public func updatePoolSize(_ size: Int) {
        precondition(size > 0, "Pool size must be positive")
        globalPoolSize = size
    }
    
    public func enablePooling(_ enabled: Bool) {
        usePoolingByDefault = enabled
    }
    
    public func installMonitor(_ newMonitor: ContextPoolMonitor?) {
        monitor = newMonitor
    }
    
    /// Configure multiple settings at once
    public func configure(
        poolSize: Int? = nil,
        poolingEnabled: Bool? = nil,
        monitor: ContextPoolMonitor? = nil
    ) {
        if let size = poolSize {
            updatePoolSize(size)
        }
        if let enabled = poolingEnabled {
            enablePooling(enabled)
        }
        if let newMonitor = monitor {
            installMonitor(newMonitor)
        }
    }
    
    /// Reset to default configuration
    public func reset() {
        globalPoolSize = 100
        usePoolingByDefault = true
        monitor = nil
    }
}