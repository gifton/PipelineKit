import Foundation

/// Global memory pressure monitor singleton.
///
/// This singleton coordinates memory pressure handling across all object pools
/// and other memory-sensitive components in the pipeline system.
public actor MemoryPressureMonitor {
    /// Shared instance
    public static let shared = MemoryPressureMonitor()
    
    /// Underlying memory pressure handler
    private let handler: MemoryPressureHandler
    
    /// Whether monitoring is active
    private var isMonitoring = false
    
    private init() {
        // **ultrathink**: Configure memory thresholds based on system memory
        // Using adaptive thresholds ensures proper behavior across different devices
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let highWaterMark = Int(Double(totalMemory) * 0.15) // 15% of total memory
        let lowWaterMark = Int(Double(totalMemory) * 0.05)  // 5% of total memory
        
        self.handler = MemoryPressureHandler(
            highWaterMark: highWaterMark,
            lowWaterMark: lowWaterMark
        )
    }
    
    /// Starts global memory pressure monitoring.
    public func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        await handler.startMonitoring()
    }
    
    /// Stops global memory pressure monitoring.
    public func stopMonitoring() async {
        guard isMonitoring else { return }
        isMonitoring = false
        await handler.stopMonitoring()
    }
    
    /// Registers a handler for memory pressure events.
    public func register(handler: @escaping @Sendable () async -> Void) async -> UUID {
        await self.handler.register(handler: handler)
    }
    
    /// Unregisters a memory pressure handler.
    public func unregister(id: UUID) async {
        await handler.unregister(id: id)
    }
    
    /// Gets current memory pressure level.
    public var pressureLevel: MemoryPressureLevel {
        get async {
            await handler.pressureLevel
        }
    }
    
    /// Gets memory pressure statistics.
    public var statistics: MemoryPressureStatistics {
        get async {
            await handler.statistics
        }
    }
}

// MARK: - Application Lifecycle Integration

public extension MemoryPressureMonitor {
    /// Call this when the application launches to start monitoring.
    func setupForApplication() async {
        await startMonitoring()
    }
    
    /// Call this when the application terminates to clean up.
    func cleanupForApplication() async {
        await stopMonitoring()
    }
}