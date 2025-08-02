import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
import mach
#endif

/// Monitors CPU usage across Apple platforms.
///
/// This monitor provides accurate CPU utilization measurements by tracking
/// processor ticks over time intervals. It handles platform differences
/// and provides fallback behavior for restricted environments.
actor CPUMonitor {
    #if os(macOS)
    // Previous CPU tick counts for calculating usage
    private var previousInfo: host_cpu_load_info?
    private var previousTime: Date?
    #endif
    
    /// Gets the current CPU usage as a percentage (0.0 to 100.0).
    ///
    /// On macOS, this uses host_processor_info to get accurate CPU tick counts.
    /// On iOS/tvOS/watchOS, CPU monitoring may be restricted.
    ///
    /// - Returns: CPU usage percentage, or 0.0 if unavailable
    func getCurrentCPUUsage() async -> Double {
        #if os(macOS)
        return await getMacOSCPUUsage()
        #else
        // iOS/tvOS/watchOS have restricted access to CPU info
        // Could potentially use process-specific metrics as a proxy
        return await getIOSCPUUsage()
        #endif
    }
    
    #if os(macOS)
    /// Gets CPU usage on macOS using host_processor_info.
    private func getMacOSCPUUsage() async -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: natural_t = 0
        var numCpus: natural_t = 0
        
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCpus,
            &cpuInfo,
            &numCpuInfo
        )
        
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 0.0
        }
        
        // Clean up memory when done
        defer {
            let size = vm_size_t(MemoryLayout<integer_t>.size * Int(numCpuInfo))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }
        
        // Calculate total ticks across all CPUs
        var totalUser: natural_t = 0
        var totalSystem: natural_t = 0
        var totalIdle: natural_t = 0
        var totalNice: natural_t = 0
        
        for i in 0..<Int32(numCpus) {
            let index = Int(CPU_STATE_MAX * i)
            totalUser += natural_t(cpuInfo[index + Int(CPU_STATE_USER)])
            totalSystem += natural_t(cpuInfo[index + Int(CPU_STATE_SYSTEM)])
            totalIdle += natural_t(cpuInfo[index + Int(CPU_STATE_IDLE)])
            totalNice += natural_t(cpuInfo[index + Int(CPU_STATE_NICE)])
        }
        
        let currentInfo = host_cpu_load_info(
            cpu_ticks: (totalUser, totalSystem, totalIdle, totalNice)
        )
        let currentTime = Date()
        
        // Calculate usage if we have previous data
        if let previousInfo = previousInfo,
           let previousTime = previousTime {
            
            let userDiff = Int(totalUser) - Int(previousInfo.cpu_ticks.0)
            let systemDiff = Int(totalSystem) - Int(previousInfo.cpu_ticks.1)
            let idleDiff = Int(totalIdle) - Int(previousInfo.cpu_ticks.2)
            let niceDiff = Int(totalNice) - Int(previousInfo.cpu_ticks.3)
            
            let totalDiff = userDiff + systemDiff + idleDiff + niceDiff
            
            if totalDiff > 0 {
                let activeDiff = userDiff + systemDiff + niceDiff
                let usage = (Double(activeDiff) / Double(totalDiff)) * 100.0
                
                // Store current data for next calculation
                self.previousInfo = currentInfo
                self.previousTime = currentTime
                
                return min(100.0, max(0.0, usage))
            }
        }
        
        // Store current data for next calculation
        self.previousInfo = currentInfo
        self.previousTime = currentTime
        
        // First call or no change - return 0
        return 0.0
    }
    #endif
    
    /// Gets CPU usage on iOS/tvOS/watchOS (limited implementation).
    private func getIOSCPUUsage() async -> Double {
        // On iOS, we can only get process-specific CPU usage
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
        
        if result == KERN_SUCCESS {
            // This gives us process CPU time, not system-wide usage
            // Return a normalized value based on processor count
            let processorCount = ProcessInfo.processInfo.activeProcessorCount
            let usage = Double(info.policy) / Double(processorCount)
            return min(100.0, max(0.0, usage))
        }
        
        return 0.0
    }
    
    /// Resets the CPU monitor, clearing previous measurements.
    func reset() {
        #if os(macOS)
        previousInfo = nil
        previousTime = nil
        #endif
    }
}

/// Extension to SystemInfo to add CPU usage monitoring.
extension SystemInfo {
    /// Shared CPU monitor instance.
    private static let cpuMonitor = CPUMonitor()
    
    /// Returns current CPU usage as a percentage (0.0 to 100.0).
    ///
    /// This method uses platform-specific APIs to get accurate CPU usage:
    /// - macOS: Uses host_processor_info for system-wide CPU usage
    /// - iOS/tvOS/watchOS: Limited to process-specific metrics
    ///
    /// Note: The first call may return 0.0 as it needs a baseline for comparison.
    static func currentCPUUsage() async -> Double {
        await cpuMonitor.getCurrentCPUUsage()
    }
    
    /// Resets CPU usage monitoring, clearing previous measurements.
    static func resetCPUMonitoring() async {
        await cpuMonitor.reset()
    }
}