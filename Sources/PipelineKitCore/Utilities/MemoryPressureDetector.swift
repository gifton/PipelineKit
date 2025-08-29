import Foundation

/// Global memory pressure detector singleton.
///
/// Coordinates memory pressure detection across all object pools and memory-sensitive
/// components. Automatically triggers cleanup handlers when memory usage exceeds
/// configurable thresholds, helping prevent out-of-memory conditions.
/// 
/// ## Overview
/// 
/// The detector monitors system memory usage and notifies registered handlers when
/// pressure thresholds are crossed. This enables proactive memory management by
/// allowing components to release cached resources before the system runs out of memory.
/// 
/// ## Usage
/// 
/// ```swift
/// // Start monitoring on app launch
/// await MemoryPressureDetector.shared.startMonitoring()
/// 
/// // Register cleanup handler for a cache
/// let handlerId = await MemoryPressureDetector.shared.register { 
///     await myCache.evictLeastRecentlyUsed(count: 100)
/// }
/// 
/// // Unregister when no longer needed
/// await MemoryPressureDetector.shared.unregister(id: handlerId)
/// ```
/// 
/// ## Thresholds
/// 
/// The detector uses adaptive thresholds based on device memory:
/// - **High watermark**: 15% of physical memory - triggers cleanup
/// - **Low watermark**: 5% of physical memory - resumes normal operation
/// 
/// These percentages ensure appropriate behavior across devices with different
/// memory capacities, from resource-constrained devices to high-memory servers.
/// 
/// ## Performance Considerations
/// 
/// - Monitoring has minimal overhead (periodic memory checks)
/// - Handlers are called asynchronously to avoid blocking
/// - Multiple handlers are executed concurrently for faster cleanup
/// 
/// - SeeAlso: `MemoryPressureResponder`, `ObjectPool`
public actor MemoryPressureDetector {
    /// Shared instance
    public static let shared = MemoryPressureDetector()
    
    /// Underlying memory pressure responder
    private let handler: MemoryPressureResponder
    
    /// Whether monitoring is active
    private var isMonitoring = false
    
    private init() {
        // Using adaptive thresholds ensures proper behavior across different devices
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let highWaterMark = Int(Double(totalMemory) * 0.15) // 15% of total memory
        let lowWaterMark = Int(Double(totalMemory) * 0.05)  // 5% of total memory
        
        self.handler = MemoryPressureResponder(
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

public extension MemoryPressureDetector {
    /// Call this when the application launches to start monitoring.
    func setupForApplication() async {
        await startMonitoring()
    }
    
    /// Call this when the application terminates to clean up.
    func cleanupForApplication() async {
        await stopMonitoring()
    }
}
