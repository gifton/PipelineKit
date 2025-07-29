import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#endif

/// Protocol for monitoring system safety during stress tests.
///
/// Safety monitors prevent stress tests from damaging the system or affecting
/// other processes. They enforce resource limits and provide emergency shutdown
/// capabilities.
public protocol SafetyMonitor: Sendable {
    /// Checks if it's safe to allocate the specified amount of memory.
    func canAllocateMemory(_ bytes: Int) async -> Bool
    
    /// Checks if it's safe to use the specified CPU percentage.
    func canUseCPU(percentage: Double, cores: Int) async -> Bool
    
    /// Checks overall system health and returns any warnings.
    func checkSystemHealth() async -> [SafetyWarning]
    
    /// Initiates emergency shutdown of all stress operations.
    func emergencyShutdown() async
}

/// Default implementation of SafetyMonitor with configurable limits.
public actor DefaultSafetyMonitor: SafetyMonitor {
    /// Maximum allowed memory usage as a percentage of total system memory.
    private let maxMemoryUsage: Double
    
    /// Maximum allowed CPU usage per core.
    private let maxCPUUsagePerCore: Double
    
    /// Watchdog timer for detecting hung operations.
    private var watchdogTimer: Task<Void, Never>?
    
    /// Current emergency shutdown state.
    private var isShutdown = false
    
    /// Callbacks to execute during emergency shutdown.
    private var shutdownHandlers: [@Sendable () async -> Void] = []
    
    public init(
        maxMemoryUsage: Double = 0.8,  // 80% of system memory
        maxCPUUsagePerCore: Double = 0.9  // 90% per core
    ) {
        self.maxMemoryUsage = maxMemoryUsage
        self.maxCPUUsagePerCore = maxCPUUsagePerCore
    }
    
    public func canAllocateMemory(_ bytes: Int) async -> Bool {
        guard !isShutdown else { return false }
        
        let systemMemory = SystemInfo.totalMemory()
        let currentUsage = SystemInfo.currentMemoryUsage()
        let projectedUsage = currentUsage + bytes
        
        let usagePercentage = Double(projectedUsage) / Double(systemMemory)
        return usagePercentage <= maxMemoryUsage
    }
    
    public func canUseCPU(percentage: Double, cores: Int) async -> Bool {
        guard !isShutdown else { return false }
        
        let totalCores = SystemInfo.cpuCoreCount()
        guard cores <= totalCores else { return false }
        
        return percentage <= maxCPUUsagePerCore
    }
    
    public func checkSystemHealth() async -> [SafetyWarning] {
        guard !isShutdown else {
            return [SafetyWarning(
                level: .critical,
                message: "System is in emergency shutdown state",
                source: "SafetyMonitor"
            )]
        }
        
        var warnings: [SafetyWarning] = []
        
        // Check memory pressure
        let memoryUsage = SystemInfo.memoryUsagePercentage()
        if memoryUsage > maxMemoryUsage {
            warnings.append(SafetyWarning(
                level: .critical,
                message: "Memory usage (\(String(format: "%.1f", memoryUsage * 100))%) exceeds safety limit",
                source: "Memory"
            ))
        } else if memoryUsage > maxMemoryUsage * 0.9 {
            warnings.append(SafetyWarning(
                level: .warning,
                message: "Memory usage (\(String(format: "%.1f", memoryUsage * 100))%) approaching limit",
                source: "Memory"
            ))
        }
        
        // Check CPU temperature if available
        if let temperature = SystemInfo.cpuTemperature(), temperature > 85.0 {
            warnings.append(SafetyWarning(
                level: .warning,
                message: "CPU temperature (\(String(format: "%.1f", temperature))°C) is high",
                source: "Temperature"
            ))
        }
        
        return warnings
    }
    
    public func emergencyShutdown() async {
        guard !isShutdown else { return }
        
        isShutdown = true
        
        // Cancel watchdog
        watchdogTimer?.cancel()
        
        // Execute all shutdown handlers
        await withTaskGroup(of: Void.self) { group in
            for handler in shutdownHandlers {
                group.addTask {
                    await handler()
                }
            }
        }
        
        print("[SafetyMonitor] Emergency shutdown completed")
    }
    
    /// Registers a handler to be called during emergency shutdown.
    public func registerShutdownHandler(_ handler: @escaping @Sendable () async -> Void) {
        shutdownHandlers.append(handler)
    }
    
    /// Starts the watchdog timer to detect hung operations.
    public func startWatchdog(timeout: TimeInterval) {
        watchdogTimer?.cancel()
        
        watchdogTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            
            if !Task.isCancelled && !isShutdown {
                print("[SafetyMonitor] Watchdog timeout - initiating emergency shutdown")
                await emergencyShutdown()
            }
        }
    }
    
    /// Resets the watchdog timer.
    public func resetWatchdog() {
        watchdogTimer?.cancel()
    }
}

// MARK: - Supporting Types

/// Warning generated by safety monitoring.
public struct SafetyWarning: Sendable {
    public enum Level: Sendable {
        case info
        case warning
        case critical
    }
    
    public let level: Level
    public let message: String
    public let source: String
    public let timestamp = Date()
    
    public init(level: Level, message: String, source: String) {
        self.level = level
        self.message = message
        self.source = source
    }
}

// MARK: - System Information

/// Utilities for gathering system information.
enum SystemInfo {
    /// Returns total system memory in bytes.
    static func totalMemory() -> Int {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var size: size_t = 0
        var len = MemoryLayout<size_t>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return Int(size)
        #else
        return 4_000_000_000 // 4GB default
        #endif
    }
    
    /// Returns current memory usage in bytes.
    static func currentMemoryUsage() -> Int {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        #else
        return 0
        #endif
    }
    
    /// Returns memory usage as a percentage of total memory.
    static func memoryUsagePercentage() -> Double {
        let total = totalMemory()
        guard total > 0 else { return 0 }
        
        let used = currentMemoryUsage()
        return Double(used) / Double(total)
    }
    
    /// Returns the number of CPU cores.
    static func cpuCoreCount() -> Int {
        ProcessInfo.processInfo.processorCount
    }
    
    /// Returns CPU temperature if available (macOS only).
    static func cpuTemperature() -> Double? {
        // This would require IOKit integration
        // Placeholder for now
        return nil
    }
}