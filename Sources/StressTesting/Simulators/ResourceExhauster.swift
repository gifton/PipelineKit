import Foundation
import PipelineKitCore
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
    
    /// Active resource allocations tracked by request ID.
    private var activeAllocations: [UUID: ResourceAllocation] = [:]
    
    /// FileHandles tracked by allocation ID for proper cleanup.
    private var allocationFileHandles: [UUID: [FileHandle]] = [:]
    
    /// Temporary file directory for disk operations.
    private var tempDirectory: URL?
    
    /// Temporary files created for disk space exhaustion.
    private var tempFiles: [URL] = []
    
    /// Resource handles for cleanup tracking.
    private var resourceHandles: [ResourceHandle<Never>] = []
    
    public init(
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector? = nil
    ) {
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
    }
    
    deinit {
        if !activeAllocations.isEmpty {
            print("⚠️ ResourceExhauster deinit with \(activeAllocations.count) active allocations. Call stopAll() before deallocation.")
        }
    }
    
    // MARK: - Public API
    
    /// Exhausts resources based on the request.
    ///
    /// This is the primary API for resource exhaustion. It handles all resource
    /// types through a unified interface and ensures proper cleanup.
    ///
    /// - Parameter request: The exhaustion request specifying resource type and amount.
    /// - Returns: Result containing allocation details and metrics.
    /// - Throws: If safety limits are exceeded or allocation fails.
    public func exhaust(_ request: ExhaustionRequest) async throws -> ExhaustionResult {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .exhaustion(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        let startTime = Date()
        state = .exhausting(resource: request.resource)
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "resource": request.resource.rawValue,
            "amount": "\(request.amount)"
        ])
        
        do {
            // Phase 1: Allocate resources
            let allocation = try await allocateResources(for: request)
            
            // Store allocation for cleanup
            activeAllocations[allocation.id] = allocation
            
            // Update state
            state = .holding(resource: request.resource, count: allocation.handles.count)
            
            // Phase 2: Hold resources (non-blocking)
            let allocationId = allocation.id
            let holdDuration = request.duration
            
            // Create a detached task for the hold phase to keep actor responsive
            Task.detached { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
                
                // Phase 3: Release resources
                await self?.releaseAndCleanup(allocationId: allocationId)
            }
            
            // Wait for the hold phase to complete
            try await Task.sleep(nanoseconds: UInt64(request.duration * 1_000_000_000))
            
            let endTime = Date()
            
            // Create result  
            let result = ExhaustionResult(
                resource: request.resource,
                requestedCount: allocation.metadata.count,
                actualCount: allocation.handles.count,
                peakUsage: Double(allocation.handles.count) / Double(allocation.metadata.count),
                duration: endTime.timeIntervalSince(startTime),
                status: .success
            )
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: result.duration,
                tags: [
                    "resource": request.resource.rawValue,
                    "success": {
                        switch result.status {
                        case .success: return "true"
                        default: return "false"
                        }
                    }()
                ])
            
            return result
        } catch {
            state = .idle
            await recordPatternFailure(.patternFail, error: error, tags: ["resource": request.resource.rawValue])
            throw error
        }
    }
    
    /// Exhausts multiple resources simultaneously.
    ///
    /// All resources are allocated together, held for the specified duration,
    /// then released together. This tests system behavior under combined load.
    ///
    /// - Parameter requests: Array of exhaustion requests.
    /// - Returns: Array of results for each request.
    /// - Throws: If any allocation fails.
    public func exhaustMultiple(_ requests: [ExhaustionRequest]) async throws -> [ExhaustionResult] {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .exhaustion(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        let startTime = Date()
        var allocations: [(ExhaustionRequest, ResourceAllocation)] = []
        var results: [ExhaustionResult] = []
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "multiple_resources",
            "resource_count": String(requests.count)
        ])
        
        do {
            // Phase 1: Allocate all resources
            for request in requests {
                state = .exhausting(resource: request.resource)
                let allocation = try await allocateResources(for: request)
                activeAllocations[allocation.id] = allocation
                allocations.append((request, allocation))
            }
            
            // Update state to show we're holding multiple resources
            state = .holding(resource: .fileDescriptors, count: allocations.count)
            
            // Phase 2: Hold all resources for the maximum duration
            let maxDuration = requests.map { $0.duration }.max() ?? 0
            try await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
            
            // Phase 3: Release all resources
            state = .releasing
            for (request, allocation) in allocations {
                await releaseAllocation(allocation)
                activeAllocations.removeValue(forKey: allocation.id)
                
                // Create result for this allocation
                let result = ExhaustionResult(
                    resource: request.resource,
                    requestedCount: allocation.metadata.count,
                    actualCount: allocation.handles.count,
                    peakUsage: Double(allocation.handles.count) / Double(allocation.metadata.count),
                    duration: Date().timeIntervalSince(allocation.metadata.allocatedAt),
                    status: .success
                )
                results.append(result)
            }
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: Date().timeIntervalSince(startTime),
                tags: [
                    "pattern": "multiple_resources",
                    "total_allocated": String(allocations.count)
                ])
            
            return results
        } catch {
            // Cleanup any successful allocations
            state = .releasing
            for (_, allocation) in allocations {
                await releaseAllocation(allocation)
                activeAllocations.removeValue(forKey: allocation.id)
            }
            state = .idle
            
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "multiple_resources"])
            throw error
        }
    }
    
    // MARK: - Private Allocation Methods
    
    /// Allocates resources based on the request.
    private func allocateResources(for request: ExhaustionRequest) async throws -> ResourceAllocation {
        let allocationStart = Date()
        var handles: [ResourceHandle<Never>] = []
        let requestedCount = try calculateRequestedCount(for: request)
        
        do {
            var osResources: OSResources
            
            switch request.resource {
            case .fileDescriptors:
                let (fdHandles, fileHandles) = try await allocateFileDescriptors(count: requestedCount)
                handles = fdHandles
                let fileDescriptors = fileHandles.map { FileDescriptor($0.fileDescriptor) }
                osResources = OSResources(type: .fileDescriptors(fileDescriptors))
                
            case .memoryMappings:
                let size = try calculateSize(from: request.amount)
                let (mmHandles, mappedRegions) = try await allocateMemoryMappings(count: requestedCount, size: size)
                handles = mmHandles
                osResources = OSResources(type: .memoryMappings(mappedRegions))
                
            case .networkSockets:
                let (sockHandles, sockets) = try await allocateSockets(count: requestedCount)
                handles = sockHandles
                osResources = OSResources(type: .networkSockets(sockets))
                
            case .diskSpace:
                let size = try calculateSize(from: request.amount)
                let (diskHandles, diskFiles) = try await allocateDiskSpace(totalSize: size, fileCount: min(requestedCount, 100))
                handles = diskHandles
                osResources = OSResources(type: .diskFiles(diskFiles.map { $0.path }))
                
            case .threads:
                let (threadHandles, tasks) = try await allocateThreads(count: requestedCount)
                handles = threadHandles
                osResources = OSResources(type: .threads(tasks))
                
            case .processes:
                let (procHandles, processes) = try await allocateProcesses(count: requestedCount)
                handles = procHandles
                osResources = OSResources(type: .processes(processes))
            }
            
            _ = Date().timeIntervalSince(allocationStart)
            
            // Record allocation metrics
            await recordGauge(.allocatedCount, value: Double(handles.count), tags: [
                "resource": request.resource.rawValue,
                "requested": String(requestedCount)
            ])
            
            return ResourceAllocation(
                type: request.resource,
                metadata: ResourceAllocation.AllocationMetadata(
                    count: requestedCount,
                    size: request.resource == .memoryMappings || request.resource == .diskSpace ? try? calculateSize(from: request.amount) : nil,
                    allocatedAt: allocationStart
                ),
                osResources: osResources,
                handles: handles
            )
        } catch {
            // Clean up any partial allocations - handles will clean up automatically
            // when they go out of scope
            
            throw error
        }
    }
    
    /// Calculates the requested count from the amount specification.
    private func calculateRequestedCount(for request: ExhaustionRequest) throws -> Int {
        switch request.amount {
        case .count(let count), .absolute(let count):
            return count
            
        case .percentage(let percentage):
            guard percentage >= 0 && percentage <= 1.0 else {
                throw PipelineError.simulation(reason: .exhaustion(.invalidAmount(reason: "Percentage must be between 0 and 1")))
            }
            
            switch request.resource {
            case .fileDescriptors:
                var rlimit = rlimit()
                getrlimit(RLIMIT_NOFILE, &rlimit)
                let maxFDs = Int(rlimit.rlim_cur)
                let currentFDs = SystemInfo.estimateCurrentFileDescriptors()
                let available = max(0, maxFDs - currentFDs)
                return Int(Double(available) * percentage)
                
            case .memoryMappings:
                // Estimate based on system memory
                let totalMemory = SystemInfo.totalMemory()
                let pageSize = Int(getpagesize())
                let maxMappings = totalMemory / (pageSize * 100)  // Assume 100 pages per mapping average
                return Int(Double(maxMappings) * percentage)
                
            case .networkSockets:
                // Similar to file descriptors
                var rlimit = rlimit()
                getrlimit(RLIMIT_NOFILE, &rlimit)
                let maxFDs = Int(rlimit.rlim_cur)
                let currentFDs = SystemInfo.estimateCurrentFileDescriptors()
                let available = max(0, maxFDs - currentFDs)
                return Int(Double(available) * percentage * 0.8)  // Leave some headroom
                
            case .threads, .processes:
                // Conservative estimate
                let maxThreads = 1000
                return Int(Double(maxThreads) * percentage)
                
            case .diskSpace:
                // For disk space, percentage applies to size, not file count
                return 10  // Default file count
            }
            
        case .bytes(let bytes):
            // For resources that use byte counts
            switch request.resource {
            case .memoryMappings:
                let pageSize = Int(getpagesize())
                return max(1, bytes / pageSize)
                
            case .diskSpace:
                return 10  // Default file count for disk operations
                
            default:
                throw PipelineError.simulation(reason: .exhaustion(.invalidAmount(reason: "Bytes specification not supported for \(request.resource)")))
            }
        }
    }
    
    /// Calculates size in bytes from amount specification.
    private func calculateSize(from amount: ExhaustionAmount) throws -> Int {
        switch amount {
        case .bytes(let bytes):
            return bytes
            
        case .percentage(let percentage):
            guard percentage >= 0 && percentage <= 1.0 else {
                throw PipelineError.simulation(reason: .exhaustion(.invalidAmount(reason: "Percentage must be between 0 and 1")))
            }
            // For percentage, use a reasonable base size
            let baseSize = 100_000_000  // 100MB base
            return Int(Double(baseSize) * percentage)
            
        case .count, .absolute:
            // For count-based amounts, use a default size
            return Int(getpagesize())  // One page per item
        }
    }
    
    /// Allocates file descriptors using SafetyMonitor.
    private func allocateFileDescriptors(count: Int) async throws -> ([ResourceHandle<Never>], [FileHandle]) {
        var handles: [ResourceHandle<Never>] = []
        var fileHandles: [FileHandle] = []
        
        defer {
            // If we have a mismatch, clean up the extra OS resources
            if fileHandles.count > handles.count {
                for i in handles.count..<fileHandles.count {
                    try? fileHandles[i].close()
                }
                fileHandles.removeLast(fileHandles.count - handles.count)
            }
        }
        
        for i in 0..<count {
            do {
                // First create actual OS resource
                let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
                
                // Then get permission from SafetyMonitor (if OS resource succeeded)
                let handle = try await safetyMonitor.allocateFileDescriptor()
                
                // Only add to arrays if both succeeded
                handles.append(handle)
                fileHandles.append(fileHandle)
                
                if (i + 1).isMultiple(of: 100) {
                    await recordGauge(.allocatedCount, value: Double(i + 1))
                }
            } catch {
                await recordCounter(.allocationFailures, tags: [
                    "resource": "file_descriptors",
                    "reason": error.localizedDescription
                ])
                break
            }
        }
        
        return (handles, fileHandles)
    }
    
    /// Allocates memory mappings using SafetyMonitor.
    private func allocateMemoryMappings(count: Int, size: Int) async throws -> ([ResourceHandle<Never>], [MappedMemory]) {
        var handles: [ResourceHandle<Never>] = []
        var mappedRegions: [MappedMemory] = []
        
        for i in 0..<count {
            do {
                // First get permission from SafetyMonitor
                let handle = try await safetyMonitor.allocateMemoryMapping(size: size)
                handles.append(handle)
                
                // Then create actual memory mapping
                let ptr = mmap(nil, size,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS,
                    -1, 0)
                
                if ptr != MAP_FAILED {
                    mappedRegions.append(MappedMemory(pointer: ptr!, size: size))
                    
                    // Touch every page to force physical memory allocation
                    let pageSize = Int(getpagesize())
                    for offset in stride(from: 0, to: size, by: pageSize) {
                        ptr!.advanced(by: offset).storeBytes(of: UInt8(0xFF), as: UInt8.self)
                    }
                } else {
                    // Remove the handle since we couldn't create the OS resource
                    handles.removeLast()
                    throw PipelineError.simulation(reason: .exhaustion(.allocationFailed(type: "memory_mapping", reason: "mmap failed")))
                }
                
                if (i + 1).isMultiple(of: 100) {
                    await recordGauge(.allocatedCount, value: Double(i + 1))
                }
            } catch {
                await recordCounter(.allocationFailures, tags: [
                    "resource": "memory_mappings",
                    "reason": error.localizedDescription
                ])
                break
            }
        }
        
        return (handles, mappedRegions)
    }
    
    /// Allocates network sockets using SafetyMonitor.
    private func allocateSockets(count: Int) async throws -> ([ResourceHandle<Never>], [Int32]) {
        var handles: [ResourceHandle<Never>] = []
        var sockets: [Int32] = []
        
        for i in 0..<count {
            do {
                // First get permission from SafetyMonitor
                let handle = try await safetyMonitor.allocateSocket(type: .tcp)
                handles.append(handle)
                
                // Then create actual socket
                let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                if sock >= 0 {
                    sockets.append(sock)
                } else {
                    // Remove the handle since we couldn't create the OS resource
                    handles.removeLast()
                    throw PipelineError.simulation(reason: .exhaustion(.allocationFailed(type: "socket", reason: "socket() failed")))
                }
                
                if (i + 1).isMultiple(of: 100) {
                    await recordGauge(.allocatedCount, value: Double(i + 1))
                }
            } catch {
                await recordCounter(.allocationFailures, tags: [
                    "resource": "network_sockets",
                    "reason": error.localizedDescription
                ])
                break
            }
        }
        
        return (handles, sockets)
    }
    
    /// Creates a sparse file at the specified URL with the given size.
    /// Sparse files don't immediately consume disk space, allowing simulation of large files.
    private func createSparseFile(at url: URL, size: Int) throws {
        // Create an empty file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        
        // Open the file and seek to the desired size
        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }
        
        // Seek to size-1 and write a single byte to create a sparse file
        if size > 0 {
            try fileHandle.seek(toOffset: UInt64(size - 1))
            fileHandle.write(Data([0]))
        }
    }
    
    /// Allocates disk space using SafetyMonitor.
    private func allocateDiskSpace(totalSize: Int, fileCount: Int) async throws -> ([ResourceHandle<Never>], [URL]) {
        var handles: [ResourceHandle<Never>] = []
        var diskFiles: [URL] = []
        
        // Create temp directory if needed
        if tempDirectory == nil {
            tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("stress-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDirectory!, withIntermediateDirectories: true)
        }
        
        let sizePerFile = totalSize / fileCount
        
        for i in 0..<fileCount {
            do {
                // First get permission from SafetyMonitor
                let handle = try await safetyMonitor.allocateDiskSpace(size: sizePerFile)
                handles.append(handle)
                
                // Then create actual file
                let fileURL = tempDirectory!.appendingPathComponent("test-\(i).dat")
                try createSparseFile(at: fileURL, size: sizePerFile)
                diskFiles.append(fileURL)
                
                await recordGauge(.allocatedSize,
                    value: Double((i + 1) * sizePerFile) / 1_000_000,  // MB
                    tags: ["unit": "mb"])
            } catch {
                // Remove the handle if file creation failed
                if handles.count > diskFiles.count {
                    handles.removeLast()
                }
                await recordCounter(.allocationFailures, tags: [
                    "resource": "disk_space",
                    "reason": error.localizedDescription
                ])
                break
            }
        }
        
        return (handles, diskFiles)
    }
    
    /// Allocates threads using SafetyMonitor.
    private func allocateThreads(count: Int) async throws -> ([ResourceHandle<Never>], [Task<Void, Never>]) {
        var handles: [ResourceHandle<Never>] = []
        var tasks: [Task<Void, Never>] = []
        
        for i in 0..<count {
            do {
                // First get permission from SafetyMonitor
                let handle = try await safetyMonitor.allocateThread()
                handles.append(handle)
                
                // Then create actual thread work
                let task = Task {
                    // Thread simulation work
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    }
                }
                tasks.append(task)
                
                if (i + 1).isMultiple(of: 10) {
                    await recordGauge(.allocatedCount, value: Double(i + 1))
                }
            } catch {
                await recordCounter(.allocationFailures, tags: [
                    "resource": "threads",
                    "reason": error.localizedDescription
                ])
                break
            }
        }
        
        return (handles, tasks)
    }
    
    /// Allocates processes using SafetyMonitor.
    private func allocateProcesses(count: Int) async throws -> ([ResourceHandle<Never>], [ProcessInfoWrapper]) {
        var handles: [ResourceHandle<Never>] = []
        var processes: [ProcessInfoWrapper] = []
        
        #if os(macOS) || os(Linux)
        for i in 0..<count {
            do {
                // First create actual subprocess
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["3600"]  // Sleep for 1 hour
                try process.run()
                
                // Then get permission from SafetyMonitor (if OS resource succeeded)
                let handle = try await safetyMonitor.allocateProcess()
                
                // Only add to arrays if both succeeded
                handles.append(handle)
                processes.append(ProcessInfoWrapper(process: process, pid: process.processIdentifier))
                
                if (i + 1).isMultiple(of: 5) {
                    await recordGauge(.allocatedCount, value: Double(i + 1))
                }
            } catch {
                // Clean up process if handle allocation failed
                if processes.count > handles.count {
                    let process = processes.removeLast().process
                    process.terminate()
                }
                await recordCounter(.allocationFailures, tags: [
                    "resource": "processes",
                    "reason": error.localizedDescription
                ])
                break
            }
        }
        #else
        // Process not available on iOS/tvOS/watchOS
        throw PipelineError.simulation(reason: .exhaustion(.allocationFailed(
            type: "processes",
            reason: "Process spawning not available on this platform"
        )))
        #endif
        
        return (handles, processes)
    }
    
    /// Releases and cleans up an allocation by ID.
    private func releaseAndCleanup(allocationId: UUID) async {
        guard let allocation = activeAllocations[allocationId] else { return }
        
        state = .releasing
        await releaseAllocation(allocation)
        activeAllocations.removeValue(forKey: allocationId)
        
        if activeAllocations.isEmpty {
            state = .idle
        }
    }
    
    /// Releases an allocation and cleans up resources.
    private func releaseAllocation(_ allocation: ResourceAllocation) async {
        // IMPORTANT: Clean up OS resources FIRST, then handles will clean up automatically
        
        switch allocation.osResources.type {
        case .fileDescriptors(let fileDescriptors):
            // Close all file descriptors
            for fd in fileDescriptors {
                close(fd)
            }
            
        case .memoryMappings(let mappedRegions):
            // Unmap all memory regions
            for region in mappedRegions {
                munmap(region.pointer, region.size)
            }
            
        case .networkSockets(let sockets):
            // Close all sockets
            for socket in sockets {
                close(socket)
            }
            
        case .diskFiles(let files):
            // Remove all files
            for file in files {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: file))
            }
            // Clean up temp directory if empty
            if let tempDir = tempDirectory {
                let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                if contents?.isEmpty ?? true {
                    try? FileManager.default.removeItem(at: tempDir)
                    tempDirectory = nil
                }
            }
            
        case .threads(let tasks):
            // Tasks are raw pointers, no cleanup needed
            _ = tasks
            
        case .processes(let processes):
            // Terminate all processes
            for processInfo in processes {
                processInfo.process.terminate()
                // Give process time to terminate gracefully
                processInfo.process.waitUntilExit()
            }
        }
        
        // Record metrics
        await recordCounter(.resourcesReleased,
            value: Double(allocation.handles.count),
            tags: ["resource": allocation.type.rawValue])
        
        // ResourceHandles will clean up automatically when deallocated
    }
    
    // MARK: - Private Cleanup Methods
    
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
        // ResourceHandles automatically clean up file descriptors, memory mappings, and sockets
        // Only disk space needs manual cleanup
        await cleanupDiskSpace()
        
        // Clear resource handles
        resourceHandles.removeAll()
    }
}

// MARK: - Supporting Types

/// Statistics for resource exhaustion.
public struct ResourceStats: Sendable {
    public let activeAllocations: Int
    public let resourcesByType: [ResourceExhauster.ResourceType: Int]
    public let sizeByType: [ResourceExhauster.ResourceType: Int]
    public let currentState: ResourceExhauster.State
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
