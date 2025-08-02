import Foundation
import Atomics
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
    
    /// Checks if it's safe to create the specified number of actors.
    func canCreateActors(count: Int) async -> Bool
    
    /// Checks if it's safe to create the specified number of tasks.
    func canCreateTasks(count: Int) async -> Bool
    
    /// Checks if it's safe to acquire the specified number of locks.
    func canAcquireLocks(count: Int) async -> Bool
    
    /// Checks if it's safe to open the specified number of file descriptors.
    func canOpenFileDescriptors(count: Int) async -> Bool
    
    /// Checks overall system health and returns any warnings.
    func checkSystemHealth() async -> [SafetyWarning]
    
    /// Returns the current safety status.
    func currentStatus() async -> SafetyStatus
    
    /// Initiates emergency shutdown of all stress operations.
    func emergencyShutdown() async
    
    // MARK: - Resource Allocation with Tracking
    
    /// Allocates an actor resource with automatic tracking.
    func allocateActor() async throws -> ResourceHandle<Never>
    
    /// Allocates a task resource with automatic tracking.
    func allocateTask() async throws -> ResourceHandle<Never>
    
    /// Allocates a lock resource with automatic tracking.
    func allocateLock() async throws -> ResourceHandle<Never>
    
    /// Allocates a file descriptor resource with automatic tracking.
    func allocateFileDescriptor() async throws -> ResourceHandle<Never>
    
    /// Allocates a memory mapping resource with automatic tracking.
    func allocateMemoryMapping(size: Int) async throws -> ResourceHandle<Never>
    
    /// Allocates a socket resource with automatic tracking.
    func allocateSocket(type: SocketType) async throws -> ResourceHandle<Never>
    
    /// Allocates disk space resource with automatic tracking.
    func allocateDiskSpace(size: Int) async throws -> ResourceHandle<Never>
    
    /// Allocates a thread resource with automatic tracking.
    func allocateThread() async throws -> ResourceHandle<Never>
    
    /// Allocates a process resource with automatic tracking.
    func allocateProcess() async throws -> ResourceHandle<Never>
    
    // MARK: - Resource Monitoring
    
    /// Returns current resource usage snapshot.
    func currentResourceUsage() async -> SafetyResourceUsage
    
    /// Detects potential resource leaks.
    func detectLeaks() async -> [ResourceLeak]
}

/// Handle for automatic resource cleanup.
public final class ResourceHandle<T>: Sendable where T: Sendable {
    private let id: UUID
    private let monitor: DefaultSafetyMonitor
    private let resourceType: SafetyResourceType
    
    init(id: UUID, monitor: DefaultSafetyMonitor, resourceType: SafetyResourceType) {
        self.id = id
        self.monitor = monitor
        self.resourceType = resourceType
    }
    
    deinit {
        // Use detached task to avoid actor isolation issues
        Task.detached { @Sendable [id, monitor, resourceType] in
            await monitor.releaseResource(id: id, type: resourceType)
        }
    }
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
    
    // MARK: - Resource Tracking
    
    /// Atomic counters for resource tracking.
    private let actorCount = ManagedAtomic<Int>(0)
    private let taskCount = ManagedAtomic<Int>(0)
    private let lockCount = ManagedAtomic<Int>(0)
    private let fdCount = ManagedAtomic<Int>(0)
    private let memoryMappingCount = ManagedAtomic<Int>(0)
    private let socketCount = ManagedAtomic<Int>(0)
    private let diskSpaceCount = ManagedAtomic<Int>(0)
    private let threadCount = ManagedAtomic<Int>(0)
    private let processCount = ManagedAtomic<Int>(0)
    
    /// Registry for leak detection with bounded capacity.
    private var resourceRegistry: LRUCache<UUID, ResourceMetadata>
    
    // MARK: - Reservation Support
    
    /// Tracks active reservations
    private var activeReservations: [UUID: ResourceReservation] = [:]
    
    /// Pending reservation counters
    private let pendingActorReservations = ManagedAtomic<Int>(0)
    private let pendingTaskReservations = ManagedAtomic<Int>(0)
    private let pendingLockReservations = ManagedAtomic<Int>(0)
    private let pendingFDReservations = ManagedAtomic<Int>(0)
    private let pendingMemoryMappingReservations = ManagedAtomic<Int>(0)
    private let pendingSocketReservations = ManagedAtomic<Int>(0)
    private let pendingDiskSpaceReservations = ManagedAtomic<Int>(0)
    private let pendingThreadReservations = ManagedAtomic<Int>(0)
    private let pendingProcessReservations = ManagedAtomic<Int>(0)
    
    public init(
        maxMemoryUsage: Double = 0.8,  // 80% of system memory
        maxCPUUsagePerCore: Double = 0.9,  // 90% per core
        resourceRegistryCapacity: Int = 10_000  // Default 10k tracked resources
    ) {
        self.maxMemoryUsage = maxMemoryUsage
        self.maxCPUUsagePerCore = maxCPUUsagePerCore
        self.resourceRegistry = LRUCache(capacity: resourceRegistryCapacity)
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
    
    public func canCreateActors(count: Int) async -> Bool {
        guard !isShutdown else { return false }
        
        // Check system resources
        let memoryUsage = SystemInfo.memoryUsagePercentage()
        if memoryUsage > maxMemoryUsage * 0.9 {
            return false
        }
        
        // Check against current count + requested + pending reservations
        let currentCount = actorCount.load(ordering: .relaxed)
        let pendingCount = pendingActorReservations.load(ordering: .relaxed)
        let projectedCount = currentCount + pendingCount + count
        
        // Dynamic limit based on system memory
        let systemMemory = SystemInfo.totalMemory()
        let maxActors = min(10_000, systemMemory / (1024 * 1024)) // 1MB per actor estimate
        
        return projectedCount <= maxActors
    }
    
    public func canCreateTasks(count: Int) async -> Bool {
        guard !isShutdown else { return false }
        
        // Check memory pressure
        let memoryUsage = SystemInfo.memoryUsagePercentage()
        if memoryUsage > maxMemoryUsage * 0.85 {
            return false
        }
        
        // Check against current count + requested + pending reservations
        let currentCount = taskCount.load(ordering: .relaxed)
        let pendingCount = pendingTaskReservations.load(ordering: .relaxed)
        let projectedCount = currentCount + pendingCount + count
        
        // Tasks are lighter than actors, allow more
        let maxTasks = 100_000  // Upper bound for safety
        return projectedCount <= maxTasks
    }
    
    public func canAcquireLocks(count: Int) async -> Bool {
        guard !isShutdown else { return false }
        
        // Check against current count + requested + pending reservations
        let currentCount = lockCount.load(ordering: .relaxed)
        let pendingCount = pendingLockReservations.load(ordering: .relaxed)
        let projectedCount = currentCount + pendingCount + count
        
        // Locks are relatively cheap but can cause deadlocks
        let maxLocks = 1_000  // Conservative limit
        return projectedCount <= maxLocks
    }
    
    public func canOpenFileDescriptors(count: Int) async -> Bool {
        guard !isShutdown else { return false }
        
        // Get system file descriptor limit
        var rlimit = rlimit()
        getrlimit(RLIMIT_NOFILE, &rlimit)
        let maxFDs = Int(rlimit.rlim_cur)
        
        // Leave headroom for system operations
        let safeLimit = Int(Double(maxFDs) * 0.8)
        
        // Check current usage (approximation) plus our tracked count + pending
        let systemFDs = SystemInfo.estimateCurrentFileDescriptors()
        let ourFDs = fdCount.load(ordering: .relaxed)
        let pendingFDs = pendingFDReservations.load(ordering: .relaxed)
        let projectedTotal = systemFDs + ourFDs + pendingFDs + count
        
        return projectedTotal <= safeLimit
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
    
    public func currentStatus() async -> SafetyStatus {
        let warnings = await checkSystemHealth()
        let criticalCount = warnings.filter { $0.level == .critical }.count
        let isHealthy = criticalCount == 0
        
        let currentResources = await currentResourceUsage()
        
        return SafetyStatus(
            isHealthy: isHealthy,
            criticalViolations: criticalCount,
            warnings: warnings,
            resourceUsage: currentResources
        )
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
    
    // MARK: - Resource Allocation Methods
    
    public func allocateActor() async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .actor)
        
        // Check system resources with pending count included
        guard await canCreateActors(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "actor", limit: maxActors))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateTask() async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .task)
        
        // Check system resources with pending count included
        guard await canCreateTasks(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "task", limit: maxTasks))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateLock() async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .lock)
        
        // Check system resources with pending count included
        guard await canAcquireLocks(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "lock", limit: maxLocks))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateFileDescriptor() async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .fileDescriptor)
        
        // Check system resources with pending count included
        guard await canOpenFileDescriptors(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "fileDescriptor", limit: maxFileDescriptors))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateMemoryMapping(size: Int) async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .memoryMapping)
        
        // Check memory safety
        guard await canAllocateMemory(size) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "memoryMapping", limit: Int(size)))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateSocket(type: SocketType) async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .socket)
        
        // Sockets use file descriptors
        guard await canOpenFileDescriptors(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "socket", limit: maxSockets))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateDiskSpace(size: Int) async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .diskSpace)
        
        // For now, just check if we can open a file descriptor for the file
        guard await canOpenFileDescriptors(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "diskSpace", limit: Int(size)))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateThread() async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .thread)
        
        // Check if we can create more threads (reuse task logic)
        guard await canCreateTasks(count: 1) else {
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "thread", limit: maxThreads))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    public func allocateProcess() async throws -> ResourceHandle<Never> {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Create reservation first
        let reservation = try await createReservation(for: .process)
        
        // Processes are heavyweight, limit to small number
        let currentCount = processCount.load(ordering: .relaxed)
        let pendingCount = pendingProcessReservations.load(ordering: .relaxed)
        let projectedCount = currentCount + pendingCount + 1
        
        guard projectedCount <= 100 else {  // Conservative limit
            await cancelReservation(reservation.value)
            throw PipelineError.resource(reason: .limitExceeded(resource: "process", limit: maxProcesses))
        }
        
        // Confirm reservation and get resource handle
        return try await confirmReservation(reservation)
    }
    
    // MARK: - Resource Monitoring
    
    public func currentResourceUsage() async -> SafetyResourceUsage {
        SafetyResourceUsage(
            actors: actorCount.load(ordering: .relaxed),
            tasks: taskCount.load(ordering: .relaxed),
            locks: lockCount.load(ordering: .relaxed),
            fileDescriptors: fdCount.load(ordering: .relaxed),
            timestamp: Date()
        )
    }
    
    public func detectLeaks() async -> [ResourceLeak] {
        let now = Date()
        let leakThreshold: TimeInterval = 300 // 5 minutes
        
        return resourceRegistry.allItems.compactMap { item in
            let age = now.timeIntervalSince(item.value.createdAt)
            if age > leakThreshold {
                return ResourceLeak(id: item.key, type: item.value.type, age: age)
            }
            return nil
        }
    }
    
    // MARK: - Internal Methods
    
    /// Releases a resource and updates counters.
    ///
    /// This method ensures that counter decrements and registry removal are
    /// coordinated to maintain consistency even in the face of crashes.
    func releaseResource(id: UUID, type: SafetyResourceType) {
        // First check if resource exists in registry
        guard let metadata = resourceRegistry.remove(id) else {
            // Resource already released or never existed
            return
        }
        
        // Verify type matches to prevent corruption
        if metadata.type != type {
            print("[SafetyMonitor] WARNING: Resource type mismatch during release. Expected \(type), found \(metadata.type)")
            // Still decrement the requested type counter to maintain consistency
        }
        
        // Decrement appropriate counter only after successful registry removal
        switch type {
        case .actor:
            actorCount.wrappingDecrement(ordering: .relaxed)
        case .task:
            taskCount.wrappingDecrement(ordering: .relaxed)
        case .lock:
            lockCount.wrappingDecrement(ordering: .relaxed)
        case .fileDescriptor:
            fdCount.wrappingDecrement(ordering: .relaxed)
        case .memoryMapping:
            memoryMappingCount.wrappingDecrement(ordering: .relaxed)
        case .socket:
            socketCount.wrappingDecrement(ordering: .relaxed)
        case .diskSpace:
            diskSpaceCount.wrappingDecrement(ordering: .relaxed)
        case .thread:
            threadCount.wrappingDecrement(ordering: .relaxed)
        case .process:
            processCount.wrappingDecrement(ordering: .relaxed)
        }
    }
    
    /// Starts periodic leak detection.
    public func startLeakDetection(interval: TimeInterval = 60) {
        Task {
            while !isShutdown {
                let leaks = await detectLeaks()
                if !leaks.isEmpty {
                    print("[SafetyMonitor] Detected \(leaks.count) potential resource leaks:")
                    for leak in leaks {
                        print("  - \(leak.type) (ID: \(leak.id)) aged \(Int(leak.age))s")
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
    
    // MARK: - Reservation Methods
    
    /// Creates a reservation for a resource without committing to allocation.
    ///
    /// This increments the pending counter but not the actual resource counter,
    /// allowing for atomic check-and-allocate operations.
    func createReservation(for resourceType: SafetyResourceType) async throws -> ReservationHandle {
        guard !isShutdown else { throw PipelineError.test(reason: "Safety monitor is shutting down") }
        
        // Increment pending counter atomically
        let pendingCounter = pendingCounter(for: resourceType)
        pendingCounter.wrappingIncrement(ordering: .relaxed)
        
        // Create reservation
        let reservation = ResourceReservation(
            id: UUID(),
            resourceType: resourceType,
            monitor: self
        )
        
        // Track reservation
        activeReservations[reservation.id] = reservation
        
        // Return handle with automatic cleanup
        return ReservationHandle(reservation: reservation)
    }
    
    /// Confirms a reservation, converting it to an actual resource allocation.
    ///
    /// This atomically moves the count from pending to allocated.
    func confirmReservation(_ handle: ReservationHandle) async throws -> ResourceHandle<Never> {
        let reservation = handle.value
        
        // Ensure reservation is still active
        guard reservation.isActive.compareExchange(
            expected: true,
            desired: false,
            ordering: .sequentiallyConsistent
        ).exchanged else {
            throw PipelineError.test(reason: "Resource reservation \(reservation.id) is no longer active")
        }
        
        // Remove from active reservations
        activeReservations.removeValue(forKey: reservation.id)
        
        // Move from pending to allocated
        let pendingCounter = pendingCounter(for: reservation.resourceType)
        let allocatedCounter = allocatedCounter(for: reservation.resourceType)
        
        // Create resource handle and metadata first
        let resourceId = UUID()
        let metadata = ResourceMetadata(
            type: reservation.resourceType,
            createdAt: Date()
        )
        
        // Add to registry before updating counters
        if let evicted = resourceRegistry.set(metadata, for: resourceId) {
            // Log eviction for debugging (resource was never cleaned up properly)
            let age = Date().timeIntervalSince(evicted.value.createdAt)
            print("[SafetyMonitor] Evicted old resource \(evicted.key) of type \(evicted.value.type) aged \(Int(age))s from registry")
            
            // Decrement counter for evicted resource to maintain consistency
            switch evicted.value.type {
            case .actor:
                actorCount.wrappingDecrement(ordering: .relaxed)
            case .task:
                taskCount.wrappingDecrement(ordering: .relaxed)
            case .lock:
                lockCount.wrappingDecrement(ordering: .relaxed)
            case .fileDescriptor:
                fdCount.wrappingDecrement(ordering: .relaxed)
            case .memoryMapping:
                memoryMappingCount.wrappingDecrement(ordering: .relaxed)
            case .socket:
                socketCount.wrappingDecrement(ordering: .relaxed)
            case .diskSpace:
                diskSpaceCount.wrappingDecrement(ordering: .relaxed)
            case .thread:
                threadCount.wrappingDecrement(ordering: .relaxed)
            case .process:
                processCount.wrappingDecrement(ordering: .relaxed)
            }
        }
        
        // Only update counters after successful registry insertion
        pendingCounter.wrappingDecrement(ordering: .relaxed)
        allocatedCounter.wrappingIncrement(ordering: .relaxed)
        
        // Periodically clean up inactive reservations
        reapInactiveReservations()
        
        return ResourceHandle(
            id: resourceId,
            monitor: self,
            resourceType: reservation.resourceType
        )
    }
    
    /// Cancels a reservation without allocating a resource.
    func cancelReservation(_ reservation: ResourceReservation) async {
        // Ensure reservation is active before cancelling
        guard reservation.isActive.compareExchange(
            expected: true,
            desired: false,
            ordering: .sequentiallyConsistent
        ).exchanged else {
            return // Already cancelled
        }
        
        // Remove from tracking
        activeReservations.removeValue(forKey: reservation.id)
        
        // Decrement pending counter
        let pendingCounter = pendingCounter(for: reservation.resourceType)
        pendingCounter.wrappingDecrement(ordering: .relaxed)
        
        // Periodically clean up inactive reservations
        reapInactiveReservations()
    }
    
    /// Handles reservation timeout
    func handleReservationTimeout(_ reservation: ResourceReservation) async {
        await cancelReservation(reservation)
        
        // Log timeout for debugging
        print("[SafetyMonitor] Reservation \(reservation.id) timed out for \(reservation.resourceType)")
    }
    
    // MARK: - Helper Methods
    
    private func pendingCounter(for type: SafetyResourceType) -> ManagedAtomic<Int> {
        switch type {
        case .actor: return pendingActorReservations
        case .task: return pendingTaskReservations
        case .lock: return pendingLockReservations
        case .fileDescriptor: return pendingFDReservations
        case .memoryMapping: return pendingMemoryMappingReservations
        case .socket: return pendingSocketReservations
        case .diskSpace: return pendingDiskSpaceReservations
        case .thread: return pendingThreadReservations
        case .process: return pendingProcessReservations
        }
    }
    
    private func allocatedCounter(for type: SafetyResourceType) -> ManagedAtomic<Int> {
        switch type {
        case .actor: return actorCount
        case .task: return taskCount
        case .lock: return lockCount
        case .fileDescriptor: return fdCount
        case .memoryMapping: return memoryMappingCount
        case .socket: return socketCount
        case .diskSpace: return diskSpaceCount
        case .thread: return threadCount
        case .process: return processCount
        }
    }
    
    /// Periodically removes inactive reservations to prevent memory growth
    private func reapInactiveReservations() {
        // Only reap every 1000 reservations to amortize cost
        guard activeReservations.count % 1_000 == 0 else { return }
        
        activeReservations = activeReservations.filter { _, reservation in
            reservation.isActive.load(ordering: .relaxed)
        }
    }
    
    /// Performs a consistency check between counters and registry.
    ///
    /// This method can detect and optionally repair inconsistencies that might
    /// occur due to crashes or bugs. Should only be called during startup or
    /// debugging.
    public func checkConsistency(repair: Bool = false) async -> ConsistencyReport {
        var report = ConsistencyReport()
        
        // Count resources by type in registry
        var registryCounts: [SafetyResourceType: Int] = [:]
        for item in resourceRegistry.allItems {
            registryCounts[item.value.type, default: 0] += 1
        }
        
        // Compare with atomic counters
        let counterValues = [
            SafetyResourceType.actor: actorCount.load(ordering: .relaxed),
            SafetyResourceType.task: taskCount.load(ordering: .relaxed),
            SafetyResourceType.lock: lockCount.load(ordering: .relaxed),
            SafetyResourceType.fileDescriptor: fdCount.load(ordering: .relaxed),
            SafetyResourceType.memoryMapping: memoryMappingCount.load(ordering: .relaxed),
            SafetyResourceType.socket: socketCount.load(ordering: .relaxed),
            SafetyResourceType.diskSpace: diskSpaceCount.load(ordering: .relaxed),
            SafetyResourceType.thread: threadCount.load(ordering: .relaxed),
            SafetyResourceType.process: processCount.load(ordering: .relaxed)
        ]
        
        // Check each resource type
        for (type, counterValue) in counterValues {
            let registryCount = registryCounts[type] ?? 0
            let diff = counterValue - registryCount
            
            if diff != 0 {
                report.inconsistencies.append(
                    ConsistencyIssue(
                        type: type,
                        counterValue: counterValue,
                        registryCount: registryCount,
                        difference: diff
                    )
                )
                
                if repair {
                    // Repair by trusting the registry as source of truth
                    switch type {
                    case .actor:
                        actorCount.store(registryCount, ordering: .relaxed)
                    case .task:
                        taskCount.store(registryCount, ordering: .relaxed)
                    case .lock:
                        lockCount.store(registryCount, ordering: .relaxed)
                    case .fileDescriptor:
                        fdCount.store(registryCount, ordering: .relaxed)
                    case .memoryMapping:
                        memoryMappingCount.store(registryCount, ordering: .relaxed)
                    case .socket:
                        socketCount.store(registryCount, ordering: .relaxed)
                    case .diskSpace:
                        diskSpaceCount.store(registryCount, ordering: .relaxed)
                    case .thread:
                        threadCount.store(registryCount, ordering: .relaxed)
                    case .process:
                        processCount.store(registryCount, ordering: .relaxed)
                    }
                    report.repaired = true
                }
            }
        }
        
        report.isConsistent = report.inconsistencies.isEmpty
        return report
    }
}

// MARK: - Supporting Types

/// Socket types for resource exhaustion.
public enum SocketType: String, Sendable {
    case tcp = "tcp"
    case udp = "udp"
}

/// Resource type enumeration for tracking.
public enum SafetyResourceType: String, Sendable {
    case actor
    case task
    case lock
    case fileDescriptor
    case memoryMapping
    case socket
    case diskSpace
    case thread
    case process
}

/// Snapshot of current resource usage.
public struct SafetyResourceUsage: Sendable {
    public let actors: Int
    public let tasks: Int
    public let locks: Int
    public let fileDescriptors: Int
    public let timestamp: Date
}

/// Metadata for tracked resources.
struct ResourceMetadata: Sendable {
    let type: SafetyResourceType
    let createdAt: Date
}

/// Represents a potential resource leak.
public struct ResourceLeak: Sendable {
    public let id: UUID
    public let type: SafetyResourceType
    public let age: TimeInterval
}

/// Report from consistency check operation.
public struct ConsistencyReport: Sendable {
    public var isConsistent: Bool = true
    public var inconsistencies: [ConsistencyIssue] = []
    public var repaired: Bool = false
}

/// Represents an inconsistency between counters and registry.
public struct ConsistencyIssue: Sendable {
    public let type: SafetyResourceType
    public let counterValue: Int
    public let registryCount: Int
    public let difference: Int
    
    public var description: String {
        "Resource type \(type): counter=\(counterValue), registry=\(registryCount), diff=\(difference)"
    }
}

/// Errors related to resource allocation.

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

/// Current safety status of the system.
public struct SafetyStatus: Sendable {
    public let isHealthy: Bool
    public let criticalViolations: Int
    public let warnings: [SafetyWarning]
    public let resourceUsage: SafetyResourceUsage
    
    public init(
        isHealthy: Bool,
        criticalViolations: Int,
        warnings: [SafetyWarning],
        resourceUsage: SafetyResourceUsage
    ) {
        self.isHealthy = isHealthy
        self.criticalViolations = criticalViolations
        self.warnings = warnings
        self.resourceUsage = resourceUsage
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
    
    /// Estimates current file descriptor usage.
    static func estimateCurrentFileDescriptors() -> Int {
        // This is a rough estimate - counting files in /dev/fd on Unix systems
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