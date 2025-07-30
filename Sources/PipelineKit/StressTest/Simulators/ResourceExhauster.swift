import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#endif

/// Simulates resource exhaustion scenarios for stress testing.
///
/// The ResourceExhauster creates controlled resource exhaustion by consuming
/// various system resources including file descriptors, memory mappings,
/// network connections, and disk space. It's designed to test system behavior
/// at resource limits.
///
/// ## Safety
///
/// All resource exhaustion is monitored by SafetyMonitor to prevent
/// permanent system damage. Resources are automatically released on cleanup.
///
/// ## Example
///
/// ```swift
/// let exhauster = ResourceExhauster(safetyMonitor: sm)
/// 
/// // Exhaust file descriptors
/// try await exhauster.exhaustFileDescriptors(
///     targetPercentage: 0.9,  // Use 90% of available FDs
///     holdDuration: 10.0      // Hold for 10 seconds
/// )
/// ```
public actor ResourceExhauster: MetricRecordable {
    // MARK: - MetricRecordable Conformance
    public typealias Namespace = ResourceMetric
    public let namespace = "resource"
    public let metricCollector: MetricCollector?
    
    /// Current exhauster state.
    public enum State: Sendable, Equatable {
        case idle
        case exhausting(resource: ResourceType)
        case holding(resource: ResourceType, count: Int)
        case releasing
    }
    
    /// Types of resources that can be exhausted.
    public enum ResourceType: String, Sendable, CaseIterable {
        case fileDescriptors = "file_descriptors"
        case memoryMappings = "memory_mappings"
        case networkSockets = "network_sockets"
        case diskSpace = "disk_space"
        case threads = "threads"
        case processes = "processes"
    }
    
    private let safetyMonitor: any SafetyMonitor
    private(set) var state: State = .idle
    
    /// Allocated resources for cleanup.
    private var fileHandles: [FileHandle] = []
    private var mappedRegions: [UnsafeMutableRawPointer] = []
    private var sockets: [Int32] = []
    private var tempFiles: [URL] = []
    private var childProcesses: [Process] = []
    private var resourceHandles: [ResourceHandle<Never>] = []
    
    /// Metrics tracking
    private var totalResourcesAllocated: [ResourceType: Int] = [:]
    private var peakResourceUsage: [ResourceType: Int] = [:]
    private var exhaustionDuration: [ResourceType: TimeInterval] = [:]
    
    public init(
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector? = nil
    ) {
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
    }
    
    /// Exhausts file descriptors up to target percentage.
    ///
    /// - Parameters:
    ///   - targetPercentage: Target FD usage (0.0-1.0).
    ///   - holdDuration: How long to hold resources.
    ///   - releaseGradually: Whether to release gradually or all at once.
    /// - Throws: If safety limits are exceeded.
    public func exhaustFileDescriptors(
        targetPercentage: Double,
        holdDuration: TimeInterval,
        releaseGradually: Bool = false
    ) async throws {
        guard state == .idle else {
            throw ResourceError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .exhausting(resource: .fileDescriptors)
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "resource": "file_descriptors",
            "target_percentage": String(format: "%.2f", targetPercentage)
        ])
        
        let startTime = Date()
        
        do {
            // Get system FD limit
            var rlimit = rlimit()
            getrlimit(RLIMIT_NOFILE, &rlimit)
            let maxFDs = Int(rlimit.rlim_cur)
            
            // Calculate target count
            let currentFDs = SystemInfo.estimateCurrentFileDescriptors()
            let targetFDs = Int(Double(maxFDs) * targetPercentage)
            let toAllocate = max(0, targetFDs - currentFDs)
            
            await recordGauge(.targetCount, value: Double(targetFDs))
            await recordGauge(.currentCount, value: Double(currentFDs))
            
            // Check safety
            guard await safetyMonitor.canOpenFileDescriptors(count: toAllocate) else {
                await recordSafetyRejection(.safetyRejection,
                    reason: "File descriptor allocation would exceed safety limits",
                    requested: "\(toAllocate) descriptors",
                    tags: ["resource": "file_descriptors"])
                
                throw ResourceError.safetyLimitExceeded(
                    requested: toAllocate,
                    reason: "Would exceed file descriptor safety limits"
                )
            }
            
            // Allocate file descriptors
            var allocated = 0
            for i in 0..<toAllocate {
                do {
                    // Try to open /dev/null for minimal resource usage
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
                    fileHandles.append(handle)
                    allocated += 1
                    
                    // Record progress periodically
                    if (i + 1) % 100 == 0 {
                        await recordGauge(.allocatedCount, value: Double(allocated))
                    }
                } catch {
                    // Stop if we can't allocate more
                    await recordCounter(.allocationFailures,
                        tags: ["resource": "file_descriptors", "reason": error.localizedDescription])
                    break
                }
            }
            
            // Update metrics
            totalResourcesAllocated[.fileDescriptors, default: 0] += allocated
            peakResourceUsage[.fileDescriptors] = max(peakResourceUsage[.fileDescriptors] ?? 0, allocated)
            
            await recordGauge(.allocatedCount, value: Double(allocated), tags: ["final": "true"])
            await recordHistogram(.allocationTime,
                value: Date().timeIntervalSince(startTime) * 1000,
                tags: ["resource": "file_descriptors"])
            
            state = .holding(resource: .fileDescriptors, count: allocated)
            
            // Hold resources
            await recordGauge(.holdStarted, value: 1)
            try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            
            // Release resources
            state = .releasing
            
            if releaseGradually {
                // Release in batches
                let batchSize = max(1, allocated / 10)
                while !fileHandles.isEmpty {
                    let toRelease = min(batchSize, fileHandles.count)
                    for _ in 0..<toRelease {
                        fileHandles.removeLast().closeFile()
                    }
                    await recordGauge(.remainingCount, value: Double(fileHandles.count))
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms between batches
                }
            } else {
                // Release all at once
                fileHandles.forEach { $0.closeFile() }
                fileHandles.removeAll()
                await recordGauge(.remainingCount, value: 0)
            }
            
            let totalDuration = Date().timeIntervalSince(startTime)
            exhaustionDuration[.fileDescriptors] = totalDuration
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: totalDuration,
                tags: ["resource": "file_descriptors", "allocated": String(allocated)])
            
        } catch {
            state = .idle
            await cleanupFileDescriptors()
            await recordPatternFailure(.patternFail, error: error, tags: ["resource": "file_descriptors"])
            throw error
        }
    }
    
    /// Exhausts memory mappings.
    ///
    /// - Parameters:
    ///   - targetCount: Number of mappings to create.
    ///   - mappingSize: Size of each mapping in bytes.
    ///   - holdDuration: How long to hold mappings.
    /// - Throws: If safety limits are exceeded.
    public func exhaustMemoryMappings(
        targetCount: Int,
        mappingSize: Int = 4096,  // Default to page size
        holdDuration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw ResourceError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .exhausting(resource: .memoryMappings)
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "resource": "memory_mappings",
            "target_count": String(targetCount),
            "mapping_size": String(mappingSize)
        ])
        
        let startTime = Date()
        
        do {
            // Check memory safety
            let totalMemory = mappingSize * targetCount
            guard await safetyMonitor.canAllocateMemory(totalMemory) else {
                await recordSafetyRejection(.safetyRejection,
                    reason: "Memory mapping would exceed safety limits",
                    requested: "\(totalMemory) bytes",
                    tags: ["resource": "memory_mappings"])
                
                throw ResourceError.safetyLimitExceeded(
                    requested: totalMemory,
                    reason: "Would exceed memory safety limits"
                )
            }
            
            // Create memory mappings
            var allocated = 0
            for i in 0..<targetCount {
                let ptr = mmap(nil, mappingSize,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS,
                    -1, 0)
                
                if ptr != MAP_FAILED {
                    mappedRegions.append(ptr!)
                    allocated += 1
                    
                    // Touch the memory to ensure it's allocated
                    ptr!.storeBytes(of: UInt8(i & 0xFF), as: UInt8.self)
                    
                    if (i + 1) % 100 == 0 {
                        await recordGauge(.allocatedCount, value: Double(allocated))
                    }
                } else {
                    await recordCounter(.allocationFailures,
                        tags: ["resource": "memory_mappings", "reason": "mmap failed"])
                    break
                }
            }
            
            // Update metrics
            totalResourcesAllocated[.memoryMappings, default: 0] += allocated
            peakResourceUsage[.memoryMappings] = max(peakResourceUsage[.memoryMappings] ?? 0, allocated)
            
            await recordGauge(.allocatedCount, value: Double(allocated), tags: ["final": "true"])
            
            state = .holding(resource: .memoryMappings, count: allocated)
            
            // Hold mappings
            try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            
            // Release mappings
            state = .releasing
            await cleanupMemoryMappings(size: mappingSize)
            
            let totalDuration = Date().timeIntervalSince(startTime)
            exhaustionDuration[.memoryMappings] = totalDuration
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: totalDuration,
                tags: ["resource": "memory_mappings", "allocated": String(allocated)])
            
        } catch {
            state = .idle
            await cleanupMemoryMappings(size: mappingSize)
            await recordPatternFailure(.patternFail, error: error, tags: ["resource": "memory_mappings"])
            throw error
        }
    }
    
    /// Exhausts network sockets.
    ///
    /// - Parameters:
    ///   - targetCount: Number of sockets to create.
    ///   - socketType: Type of socket (TCP/UDP).
    ///   - holdDuration: How long to hold sockets.
    /// - Throws: If safety limits are exceeded.
    public func exhaustNetworkSockets(
        targetCount: Int,
        socketType: SocketType = .tcp,
        holdDuration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw ResourceError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .exhausting(resource: .networkSockets)
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "resource": "network_sockets",
            "target_count": String(targetCount),
            "socket_type": socketType.rawValue
        ])
        
        let startTime = Date()
        
        do {
            // Check file descriptor safety (sockets use FDs)
            guard await safetyMonitor.canOpenFileDescriptors(count: targetCount) else {
                await recordSafetyRejection(.safetyRejection,
                    reason: "Socket creation would exceed file descriptor limits",
                    requested: "\(targetCount) sockets",
                    tags: ["resource": "network_sockets"])
                
                throw ResourceError.safetyLimitExceeded(
                    requested: targetCount,
                    reason: "Would exceed file descriptor limits"
                )
            }
            
            // Create sockets
            var allocated = 0
            let protocolType = socketType == .tcp ? IPPROTO_TCP : IPPROTO_UDP
            
            for i in 0..<targetCount {
                let sock = socket(AF_INET, socketType == .tcp ? SOCK_STREAM : SOCK_DGRAM, protocolType)
                if sock >= 0 {
                    sockets.append(sock)
                    allocated += 1
                    
                    if (i + 1) % 100 == 0 {
                        await recordGauge(.allocatedCount, value: Double(allocated))
                    }
                } else {
                    await recordCounter(.allocationFailures,
                        tags: ["resource": "network_sockets", "reason": "socket() failed"])
                    break
                }
            }
            
            // Update metrics
            totalResourcesAllocated[.networkSockets, default: 0] += allocated
            peakResourceUsage[.networkSockets] = max(peakResourceUsage[.networkSockets] ?? 0, allocated)
            
            await recordGauge(.allocatedCount, value: Double(allocated), tags: ["final": "true"])
            
            state = .holding(resource: .networkSockets, count: allocated)
            
            // Hold sockets
            try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            
            // Release sockets
            state = .releasing
            await cleanupSockets()
            
            let totalDuration = Date().timeIntervalSince(startTime)
            exhaustionDuration[.networkSockets] = totalDuration
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: totalDuration,
                tags: ["resource": "network_sockets", "allocated": String(allocated)])
            
        } catch {
            state = .idle
            await cleanupSockets()
            await recordPatternFailure(.patternFail, error: error, tags: ["resource": "network_sockets"])
            throw error
        }
    }
    
    /// Exhausts disk space by creating temporary files.
    ///
    /// - Parameters:
    ///   - targetSize: Total size to allocate in bytes.
    ///   - fileCount: Number of files to spread allocation across.
    ///   - holdDuration: How long to hold files.
    /// - Throws: If safety limits are exceeded.
    public func exhaustDiskSpace(
        targetSize: Int,
        fileCount: Int = 10,
        holdDuration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw ResourceError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .exhausting(resource: .diskSpace)
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "resource": "disk_space",
            "target_size": String(targetSize),
            "file_count": String(fileCount)
        ])
        
        let startTime = Date()
        let sizePerFile = targetSize / fileCount
        
        do {
            // Create temporary directory
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("stress-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            var allocatedSize = 0
            var allocatedFiles = 0
            
            // Create files using sparse file technique to avoid memory exhaustion
            for i in 0..<fileCount {
                let fileURL = tempDir.appendingPathComponent("test-\(i).dat")
                
                do {
                    // Create sparse file without allocating memory
                    try createSparseFile(at: fileURL, size: sizePerFile)
                    
                    tempFiles.append(fileURL)
                    allocatedFiles += 1
                    allocatedSize += sizePerFile
                    
                    await recordGauge(.allocatedSize,
                        value: Double(allocatedSize) / 1_000_000,  // MB
                        tags: ["unit": "mb"])
                } catch {
                    await recordCounter(.allocationFailures,
                        tags: ["resource": "disk_space", "reason": error.localizedDescription])
                    break
                }
            }
            
            // Update metrics
            totalResourcesAllocated[.diskSpace, default: 0] += allocatedSize
            peakResourceUsage[.diskSpace] = max(peakResourceUsage[.diskSpace] ?? 0, allocatedSize)
            
            state = .holding(resource: .diskSpace, count: allocatedFiles)
            
            // Hold files
            try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            
            // Cleanup
            state = .releasing
            await cleanupDiskSpace()
            
            // Remove temp directory
            try? FileManager.default.removeItem(at: tempDir)
            
            let totalDuration = Date().timeIntervalSince(startTime)
            exhaustionDuration[.diskSpace] = totalDuration
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: totalDuration,
                tags: ["resource": "disk_space", "allocated_mb": String(allocatedSize / 1_000_000)])
            
        } catch {
            state = .idle
            await cleanupDiskSpace()
            await recordPatternFailure(.patternFail, error: error, tags: ["resource": "disk_space"])
            throw error
        }
    }
    
    /// Creates a sparse file without allocating memory.
    ///
    /// This technique creates a file of the specified size without actually
    /// writing data, avoiding memory allocation. The file appears to be the
    /// full size but only uses disk blocks as they are written to.
    ///
    /// - Parameters:
    ///   - url: The file URL to create.
    ///   - size: The size in bytes.
    /// - Throws: If file creation fails.
    private func createSparseFile(at url: URL, size: Int) throws {
        // Create empty file
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        
        // Open file handle and extend to desired size
        let handle = try FileHandle(forWritingTo: url)
        defer { 
            try? handle.close()
        }
        
        // Seek to desired size and write a single byte to extend the file
        // This creates a sparse file on most filesystems
        if size > 0 {
            try handle.seek(toOffset: UInt64(size - 1))
            handle.write(Data([0]))
        }
    }
    
    /// Exhausts multiple resources simultaneously.
    ///
    /// - Parameters:
    ///   - resources: Dictionary of resource types to their target usage.
    ///   - holdDuration: How long to hold all resources.
    /// - Throws: If any resource exhaustion fails.
    public func exhaustMultipleResources(
        resources: [ResourceType: Double],  // Resource -> target percentage
        holdDuration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw ResourceError.invalidState(current: "\(state)", expected: "idle")
        }
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "multiple_resources",
            "resource_count": String(resources.count)
        ])
        
        let startTime = Date()
        var exhaustedResources: [ResourceType] = []
        
        do {
            // Exhaust each resource type
            for (resourceType, targetUsage) in resources {
                switch resourceType {
                case .fileDescriptors:
                    try await exhaustFileDescriptors(
                        targetPercentage: targetUsage,
                        holdDuration: 0  // Don't hold individually
                    )
                case .memoryMappings:
                    let count = Int(targetUsage * 1000)  // Convert percentage to count
                    try await exhaustMemoryMappings(
                        targetCount: count,
                        holdDuration: 0
                    )
                case .networkSockets:
                    let count = Int(targetUsage * 100)  // Convert percentage to count
                    try await exhaustNetworkSockets(
                        targetCount: count,
                        holdDuration: 0
                    )
                case .diskSpace:
                    let size = Int(targetUsage * 100_000_000)  // 100MB base
                    try await exhaustDiskSpace(
                        targetSize: size,
                        holdDuration: 0
                    )
                default:
                    continue
                }
                
                exhaustedResources.append(resourceType)
                await recordCounter(.resourcesExhausted,
                    tags: ["resource": resourceType.rawValue])
            }
            
            // Hold all resources together
            state = .holding(resource: .fileDescriptors, count: exhaustedResources.count)
            try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            
            // Cleanup all
            await cleanupAll()
            
            let totalDuration = Date().timeIntervalSince(startTime)
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: totalDuration,
                tags: ["pattern": "multiple_resources", "exhausted": String(exhaustedResources.count)])
            
        } catch {
            state = .idle
            await cleanupAll()
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "multiple_resources"])
            throw error
        }
    }
    
    /// Stops all resource exhaustion and releases resources.
    public func stopAll() async {
        state = .releasing
        await cleanupAll()
        state = .idle
        
        // Record final metrics
        for (resourceType, count) in totalResourcesAllocated {
            await recordGauge(.totalAllocated,
                value: Double(count),
                tags: ["resource": resourceType.rawValue, "final": "true"])
        }
        
        for (resourceType, peak) in peakResourceUsage {
            await recordGauge(.peakUsage,
                value: Double(peak),
                tags: ["resource": resourceType.rawValue, "final": "true"])
        }
    }
    
    /// Returns current exhaustion statistics.
    public func currentStats() -> ResourceStats {
        ResourceStats(
            totalAllocated: totalResourcesAllocated,
            peakUsage: peakResourceUsage,
            exhaustionDuration: exhaustionDuration,
            currentState: state
        )
    }
    
    // MARK: - Private Cleanup Methods
    
    private func cleanupFileDescriptors() async {
        let count = fileHandles.count
        fileHandles.forEach { $0.closeFile() }
        fileHandles.removeAll()
        
        if count > 0 {
            await recordCounter(.resourcesReleased,
                value: Double(count),
                tags: ["resource": "file_descriptors"])
        }
    }
    
    private func cleanupMemoryMappings(size: Int) async {
        let count = mappedRegions.count
        for ptr in mappedRegions {
            munmap(ptr, size)
        }
        mappedRegions.removeAll()
        
        if count > 0 {
            await recordCounter(.resourcesReleased,
                value: Double(count),
                tags: ["resource": "memory_mappings"])
        }
    }
    
    private func cleanupSockets() async {
        let count = sockets.count
        for sock in sockets {
            close(sock)
        }
        sockets.removeAll()
        
        if count > 0 {
            await recordCounter(.resourcesReleased,
                value: Double(count),
                tags: ["resource": "network_sockets"])
        }
    }
    
    private func cleanupDiskSpace() async {
        let count = tempFiles.count
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
        
        if count > 0 {
            await recordCounter(.resourcesReleased,
                value: Double(count),
                tags: ["resource": "disk_space"])
        }
    }
    
    private func cleanupAll() async {
        await cleanupFileDescriptors()
        await cleanupMemoryMappings(size: 4096)  // Default page size
        await cleanupSockets()
        await cleanupDiskSpace()
        
        // Clear resource handles
        resourceHandles.removeAll()
    }
}

// MARK: - Supporting Types

/// Socket types for exhaustion.
public enum SocketType: String, Sendable {
    case tcp = "tcp"
    case udp = "udp"
}

/// Statistics for resource exhaustion.
public struct ResourceStats: Sendable {
    public let totalAllocated: [ResourceExhauster.ResourceType: Int]
    public let peakUsage: [ResourceExhauster.ResourceType: Int]
    public let exhaustionDuration: [ResourceExhauster.ResourceType: TimeInterval]
    public let currentState: ResourceExhauster.State
}

/// Errors specific to resource exhaustion.
public enum ResourceError: LocalizedError {
    case invalidState(current: String, expected: String)
    case safetyLimitExceeded(requested: Int, reason: String)
    case allocationFailed(type: String, reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidState(let current, let expected):
            return "Invalid exhauster state: \(current), expected \(expected)"
        case .safetyLimitExceeded(let requested, let reason):
            return "Safety limit exceeded: requested \(requested) - \(reason)"
        case .allocationFailed(let type, let reason):
            return "Failed to allocate \(type): \(reason)"
        }
    }
}

/// Resource exhaustion metrics namespace.
public enum ResourceMetric: String {
    // Pattern lifecycle
    case patternStart = "pattern.start"
    case patternComplete = "pattern.complete"
    case patternFail = "pattern.fail"
    
    // Resource counts
    case targetCount = "target.count"
    case currentCount = "current.count"
    case allocatedCount = "allocated.count"
    case remainingCount = "remaining.count"
    case allocatedSize = "allocated.size"
    
    // Resource tracking
    case totalAllocated = "total.allocated"
    case peakUsage = "peak.usage"
    case resourcesExhausted = "resources.exhausted"
    case resourcesReleased = "resources.released"
    
    // Timing
    case allocationTime = "allocation.time"
    case holdStarted = "hold.started"
    
    // Failures
    case allocationFailures = "allocation.failures"
    case safetyRejection = "safety.rejection"
}

// MARK: - System Information Extension

extension SystemInfo {
    /// Estimates current file descriptor usage.
    static func estimateCurrentFileDescriptors() -> Int {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let fdPath = "/dev/fd"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: fdPath)
            return contents.count
        } catch {
            // Fallback: assume some baseline usage
            return 10
        }
        #else
        return 10  // Conservative estimate
        #endif
    }
}