@preconcurrency import Foundation
@preconcurrency import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// Responds to system memory pressure events and coordinates pool cleanup.
///
/// This component monitors system memory conditions and automatically
/// adjusts object pools to prevent excessive memory usage during pressure.
public actor MemoryPressureResponder {
    /// Closure type for memory pressure callbacks
    public typealias Handler = @Sendable () async -> Void
    
    /// Registered handlers to execute on memory warnings
    private var handlers: [UUID: Handler] = [:]
    
    /// Current memory pressure level
    private var currentPressureLevel: MemoryPressureLevel = .normal
    
    /// Statistics for monitoring
    private var stats = MemoryPressureStatistics()
    
    /// High water mark for available memory (bytes)
    private let highWaterMark: Int
    
    /// Low water mark for available memory (bytes)
    private let lowWaterMark: Int
    
    /// Timer for periodic memory checks
    private var monitoringTask: Task<Void, Never>?
    
    /// Creates a new memory pressure handler.
    ///
    /// - Parameters:
    ///   - highWaterMark: Memory threshold for normal operations (default: 100MB)
    ///   - lowWaterMark: Memory threshold for aggressive cleanup (default: 50MB)
    public init(
        highWaterMark: Int = 100 * 1024 * 1024,  // 100MB
        lowWaterMark: Int = 50 * 1024 * 1024     // 50MB
    ) {
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
    }
    
    /// Starts monitoring system memory pressure.
    public func startMonitoring() {
        guard monitoringTask == nil else { return }
        
        #if canImport(UIKit)
        // iOS memory warning notifications
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task {
                    await self?.handleMemoryWarning()
                }
            }
        }
        #endif
        
        // Start periodic monitoring
        monitoringTask = Task {
            await monitorPeriodicMemoryPressure()
        }
    }
    
    /// Stops monitoring system memory pressure.
    public func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        
        #if canImport(UIKit)
        Task { @MainActor in
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }
        #endif
    }
    
    /// Registers a handler to be called during memory pressure.
    ///
    /// - Parameter handler: Async closure to execute during memory pressure
    /// - Returns: Registration ID that can be used to unregister
    @discardableResult
    public func register(handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }
    
    /// Unregisters a memory pressure handler.
    ///
    /// - Parameter id: The registration ID returned from register
    public func unregister(id: UUID) {
        handlers.removeValue(forKey: id)
    }
    
    /// Gets current memory pressure statistics.
    public var statistics: MemoryPressureStatistics {
        stats
    }
    
    /// Gets current memory pressure level.
    public var pressureLevel: MemoryPressureLevel {
        currentPressureLevel
    }
    
    // MARK: - Private Methods
    
    private func monitorPeriodicMemoryPressure() async {
        while !Task.isCancelled {
            // Check memory every 5 seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            
            let availableMemory = getAvailableMemory()
            let previousLevel = currentPressureLevel
            
            // Determine pressure level based on available memory
            if availableMemory < lowWaterMark {
                currentPressureLevel = .critical
            } else if availableMemory < highWaterMark {
                currentPressureLevel = .warning
            } else {
                currentPressureLevel = .normal
            }
            
            // Trigger handlers if pressure increased
            if currentPressureLevel.rawValue > previousLevel.rawValue {
                await handleMemoryPressure(level: currentPressureLevel)
            }
            
            stats.periodicChecks += 1
        }
    }
    
    private func handleMemoryWarning() async {
        stats.systemWarnings += 1
        currentPressureLevel = .critical
        await handleMemoryPressure(level: .critical)
    }
    
    internal func handleMemoryPressure(level: MemoryPressureLevel) async {
        stats.pressureEvents += 1
        
        // Execute all registered handlers concurrently
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers.values {
                group.addTask {
                    await handler()
                }
            }
        }
    }
    
    private func getAvailableMemory() -> Int {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        
        if result == KERN_SUCCESS {
            // Return physical memory limit minus resident size
            let limit = ProcessInfo.processInfo.physicalMemory
            return Int(limit) - Int(info.resident_size)
        }
        #endif
        
        // Fallback: use ProcessInfo
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let usedMemory = getMemoryUsage()
        return Int(totalMemory) - usedMemory
    }
    
    private func getMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}

/// Memory pressure levels.
public enum MemoryPressureLevel: Int, Sendable {
    /// Normal memory conditions
    case normal = 0
    
    /// Memory usage approaching limits
    case warning = 1
    
    /// Critical memory pressure
    case critical = 2
}

/// Statistics for memory pressure monitoring.
public struct MemoryPressureStatistics: Sendable {
    /// Number of system memory warnings received
    public var systemWarnings: Int = 0
    
    /// Number of pressure events handled
    public var pressureEvents: Int = 0
    
    /// Number of periodic memory checks
    public var periodicChecks: Int = 0
}
