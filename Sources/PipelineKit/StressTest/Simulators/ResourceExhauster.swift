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
    
    /// Legacy arrays for backwards compatibility with cleanup methods
    private var fileHandles: [FileHandle] = []
    private var mappedRegions: [UnsafeMutableRawPointer] = []
    private var sockets: [Int32] = []
    
    /// Legacy tracking for backwards compatibility
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
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
                // Store FileHandles in our internal array for cleanup
                self.fileHandles.append(contentsOf: fileHandles)
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
            
            let allocationTime = Date().timeIntervalSince(allocationStart)
            
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
                throw ResourceExhausterError.invalidAmount("Percentage must be between 0 and 1")
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
                throw ResourceExhausterError.invalidAmount("Bytes specification not supported for \(request.resource)")
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
                throw ResourceExhausterError.invalidAmount("Percentage must be between 0 and 1")
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
                
                if (i + 1) % 100 == 0 {
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
                    throw ResourceExhausterError.allocationFailed(type: "memory_mapping", reason: "mmap failed")
                }
                
                if (i + 1) % 100 == 0 {
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
                    throw ResourceExhausterError.allocationFailed(type: "socket", reason: "socket() failed")
                }
                
                if (i + 1) % 100 == 0 {
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
                
                if (i + 1) % 10 == 0 {
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
                
                if (i + 1) % 5 == 0 {
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
        throw ResourceExhausterError.allocationFailed(
            type: "processes",
            reason: "Process spawning not available on this platform"
        )
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
            // Also close and remove corresponding FileHandles from our internal array
            self.fileHandles.removeAll { handle in
                fileDescriptors.contains(FileDescriptor(handle.fileDescriptor))
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
    
    /// Exhausts file descriptors up to target percentage.
    // MARK: - Legacy API (Deprecated)
    
    /// Legacy method for file descriptor exhaustion.
    /// - Deprecated: Use `exhaust(_:)` with an `ExhaustionRequest` instead.
    @available(*, deprecated, message: "Use exhaust(_:) with an ExhaustionRequest instead")
    public func exhaustFileDescriptors(
        targetPercentage: Double,
        holdDuration: TimeInterval,
        releaseGradually: Bool = false
    ) async throws {
        guard state == .idle else {
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
                
                throw ResourceExhausterError.safetyLimitExceeded(
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
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
                
                throw ResourceExhausterError.safetyLimitExceeded(
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
                    
                    // Touch every page to force physical memory allocation
                    let pageSize = Int(getpagesize())
                    for offset in stride(from: 0, to: mappingSize, by: pageSize) {
                        ptr!.advanced(by: offset).storeBytes(of: UInt8(0xFF), as: UInt8.self)
                    }
                    
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
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
                
                throw ResourceExhausterError.safetyLimitExceeded(
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
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
            throw ResourceExhausterError.invalidState(current: "\(state)", expected: "idle")
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
        
        // Release all active allocations
        for allocation in activeAllocations.values {
            await releaseAllocation(allocation)
        }
        activeAllocations.removeAll()
        
        // Clean up temp directory
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
            tempDirectory = nil
        }
        
        state = .idle
        
        // Record final metrics
        await recordGauge(.allocatedCount, value: 0, tags: ["final": "true"])
    }
    
    /// Returns current exhaustion statistics.
    public func currentStats() -> ResourceStats {
        var totalByType: [ResourceType: Int] = [:]
        var sizeByType: [ResourceType: Int] = [:]
        
        for allocation in activeAllocations.values {
            totalByType[allocation.type, default: 0] += allocation.handles.count
            if let size = allocation.metadata.size {
                sizeByType[allocation.type, default: 0] += size
            }
        }
        
        return ResourceStats(
            activeAllocations: activeAllocations.count,
            resourcesByType: totalByType,
            sizeByType: sizeByType,
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

/// Errors specific to resource exhaustion.
public enum ResourceExhausterError: LocalizedError {
    case invalidState(current: String, expected: String)
    case safetyLimitExceeded(requested: Int, reason: String)
    case allocationFailed(type: String, reason: String)
    case invalidAmount(_ reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidState(let current, let expected):
            return "Invalid exhauster state: \(current), expected \(expected)"
        case .safetyLimitExceeded(let requested, let reason):
            return "Safety limit exceeded: requested \(requested) - \(reason)"
        case .allocationFailed(let type, let reason):
            return "Failed to allocate \(type): \(reason)"
        case .invalidAmount(let reason):
            return "Invalid amount specification: \(reason)"
        }
    }
}

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

