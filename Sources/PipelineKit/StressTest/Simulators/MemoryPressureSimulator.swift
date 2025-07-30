import Foundation

/// Simulates memory pressure scenarios for stress testing.
///
/// The MemoryPressureSimulator creates controlled memory pressure by allocating
/// and managing memory buffers. It supports various pressure patterns including
/// gradual increase, burst allocation, and oscillating pressure.
///
/// ## Safety
///
/// All allocations are tracked through ResourceManager and validated by SafetyMonitor
/// to prevent system damage. The simulator automatically releases memory if safety
/// limits are exceeded.
///
/// ## Example
///
/// ```swift
/// let simulator = MemoryPressureSimulator(resourceManager: rm, safetyMonitor: sm)
/// 
/// // Apply gradual pressure up to 70% usage over 30 seconds
/// try await simulator.applyGradualPressure(targetUsage: 0.7, duration: 30)
/// 
/// // Create burst allocation
/// try await simulator.burst(size: 100_000_000, holdTime: 5.0)
/// ```
public actor MemoryPressureSimulator: MetricRecordable {
    // MARK: - MetricRecordable Conformance
    public typealias Namespace = MemoryMetric
    public let namespace = "memory"
    /// Current simulator state.
    public enum State: Sendable, Equatable {
        case idle
        case applying(pattern: PressurePattern)
        case holding(size: Int)
        case releasing
    }
    
    /// Memory pressure patterns.
    public enum PressurePattern: Sendable, Equatable {
        case gradual(targetUsage: Double, duration: TimeInterval)
        case burst(size: Int, count: Int)
        case oscillating(minUsage: Double, maxUsage: Double, period: TimeInterval)
        case stepped(steps: [Double], holdTime: TimeInterval)
    }
    
    private let resourceManager: ResourceManager
    private let safetyMonitor: any SafetyMonitor
    public let metricCollector: MetricCollector?
    private(set) var state: State = .idle
    
    /// Currently allocated buffers.
    private var allocatedBuffers: [UUID: AllocatedBuffer] = [:]
    
    /// Total allocated memory.
    private var totalAllocated: Int = 0
    
    /// Active pressure task.
    private var pressureTask: Task<Void, Error>?
    
    /// Metrics tracking
    private var allocationCount: Int = 0
    private var releaseCount: Int = 0
    private var startTime: Date?
    
    public init(
        resourceManager: ResourceManager,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector? = nil
    ) {
        self.resourceManager = resourceManager
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
    }
    
    /// Applies gradual memory pressure up to target usage.
    ///
    /// - Parameters:
    ///   - targetUsage: Target memory usage as percentage (0.0 to 1.0).
    ///   - duration: Time to reach target pressure.
    ///   - stepSize: Size of each allocation step in bytes.
    /// - Throws: If safety limits are exceeded or allocation fails.
    public func applyGradualPressure(
        targetUsage: Double,
        duration: TimeInterval,
        stepSize: Int = 10_000_000  // 10MB steps
    ) async throws {
        guard state == .idle else {
            throw SimulatorError.invalidState(current: state, expected: .idle)
        }
        
        startTime = Date()
        state = .applying(pattern: .gradual(targetUsage: targetUsage, duration: duration))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "gradual",
            "target_usage": String(targetUsage)
        ])
        
        pressureTask = Task { try await performGradualPressure(targetUsage, duration, stepSize) }
        
        do {
            try await pressureTask!.value
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete, 
                duration: Date().timeIntervalSince(startTime ?? Date()),
                tags: ["pattern": "gradual"])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "gradual"])
            
            throw error
        }
    }
    
    /// Creates a burst memory allocation.
    ///
    /// - Parameters:
    ///   - size: Size of allocation in bytes.
    ///   - holdTime: Time to hold the allocation.
    /// - Throws: If safety limits are exceeded or allocation fails.
    public func burst(size: Int, holdTime: TimeInterval) async throws {
        guard state == .idle else {
            throw SimulatorError.invalidState(current: state, expected: .idle)
        }
        
        startTime = Date()
        
        // Record burst start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "burst",
            "size": String(size)
        ])
        
        // Check safety before allocation
        guard await safetyMonitor.canAllocateMemory(size) else {
            await recordSafetyRejection(.safetyRejection,
                reason: "Memory allocation would exceed safety limits",
                requested: String(size),
                tags: ["pattern": "burst"])
            
            throw SimulatorError.safetyLimitExceeded(
                requested: size,
                reason: "Memory allocation would exceed safety limits"
            )
        }
        
        state = .applying(pattern: .burst(size: size, count: 1))
        
        do {
            let burstStart = Date()
            
            // Allocate memory
            let buffer = try await allocateBuffer(size: size)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += size
            
            let allocationLatency = Date().timeIntervalSince(burstStart)
            await recordLatency(.allocationLatency, seconds: allocationLatency, tags: ["pattern": "burst"])
            await recordGauge(.allocationSize, value: Double(size), tags: ["pattern": "burst"])
            
            state = .holding(size: size)
            await recordPressureLevel()
            
            // Hold for specified time
            try await Task.sleep(nanoseconds: UInt64(holdTime * 1_000_000_000))
            
            // Release
            state = .releasing
            let releaseStart = Date()
            try await releaseBuffer(buffer.id)
            
            let releaseLatency = Date().timeIntervalSince(releaseStart)
            await recordLatency(.releaseDuration, seconds: releaseLatency, tags: ["pattern": "burst"])
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: Date().timeIntervalSince(startTime ?? Date()),
                tags: ["pattern": "burst"])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "burst"])
            
            // Ensure cleanup on error
            await releaseAll()
            throw error
        }
    }
    
    /// Applies oscillating memory pressure.
    ///
    /// - Parameters:
    ///   - minUsage: Minimum memory usage percentage.
    ///   - maxUsage: Maximum memory usage percentage.
    ///   - period: Time for one complete oscillation.
    ///   - cycles: Number of oscillation cycles.
    /// - Throws: If safety limits are exceeded or allocation fails.
    public func oscillate(
        minUsage: Double,
        maxUsage: Double,
        period: TimeInterval,
        cycles: Int = 3
    ) async throws {
        guard state == .idle else {
            throw SimulatorError.invalidState(current: state, expected: .idle)
        }
        
        startTime = Date()
        state = .applying(pattern: .oscillating(minUsage: minUsage, maxUsage: maxUsage, period: period))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "oscillating",
            "min_usage": String(minUsage),
            "max_usage": String(maxUsage),
            "period": String(period)
        ])
        
        pressureTask = Task {
            for cycle in 0..<cycles {
                try Task.checkCancellation()
                
                let cycleStart = Date()
                
                // Record cycle start
                await recordGauge(.oscillationCycle, value: Double(cycle + 1), tags: [
                    "phase": "start",
                    "target": "max"
                ])
                
                // Ramp up to max
                try await performGradualPressure(maxUsage, period / 2)
                
                // Record peak
                await recordGauge(.oscillationPeak, value: maxUsage * 100, tags: [
                    "cycle": String(cycle + 1)
                ])
                await recordPressureLevel()
                
                // Record cycle midpoint
                await recordGauge(.oscillationCycle, value: Double(cycle + 1), tags: [
                    "phase": "midpoint",
                    "target": "min"
                ])
                
                // Ramp down to min
                try await releaseToUsage(minUsage, duration: period / 2)
                
                // Record trough
                await recordGauge(.oscillationTrough, value: minUsage * 100, tags: [
                    "cycle": String(cycle + 1)
                ])
                await recordPressureLevel()
                
                let cycleDuration = Date().timeIntervalSince(cycleStart)
                await recordHistogram(.oscillationCycle, value: cycleDuration, tags: ["metric": "duration"])
            }
        }
        
        do {
            try await pressureTask!.value
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: Date().timeIntervalSince(startTime ?? Date()),
                tags: [
                    "pattern": "oscillating",
                    "cycles": String(cycles)
                ])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "oscillating"])
            
            throw error
        }
    }
    
    /// Applies stepped memory pressure with plateaus.
    ///
    /// - Parameters:
    ///   - steps: Array of target usage percentages.
    ///   - holdTime: Time to hold at each step.
    /// - Throws: If safety limits are exceeded or allocation fails.
    public func stepped(
        steps: [Double],
        holdTime: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw SimulatorError.invalidState(current: state, expected: .idle)
        }
        
        startTime = Date()
        state = .applying(pattern: .stepped(steps: steps, holdTime: holdTime))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "stepped",
            "steps": String(steps.count),
            "hold_time": String(holdTime)
        ])
        
        pressureTask = Task {
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                
                let stepStart = Date()
                
                // Record step start
                await recordGauge(.steppedLevel, value: Double(index + 1), tags: [
                    "target_usage": String(step),
                    "total_steps": String(steps.count),
                    "metric": "current_step"
                ])
                
                // Reach target
                try await performGradualPressure(step, 2.0)  // 2 seconds to reach each step
                
                // Record reaching the step
                await recordGauge(.steppedLevel, value: step * 100, tags: [
                    "step": String(index + 1)
                ])
                await recordPressureLevel()
                
                // Hold
                try await Task.sleep(nanoseconds: UInt64(holdTime * 1_000_000_000))
                
                let stepDuration = Date().timeIntervalSince(stepStart)
                await recordHistogram(.steppedLevel, value: stepDuration, tags: [
                    "step": String(index + 1),
                    "metric": "duration"
                ])
            }
        }
        
        do {
            try await pressureTask!.value
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: Date().timeIntervalSince(startTime ?? Date()),
                tags: [
                    "pattern": "stepped",
                    "steps_completed": String(steps.count)
                ])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "stepped"])
            
            throw error
        }
    }
    
    /// Releases all allocated memory.
    public func releaseAll() async {
        state = .releasing
        pressureTask?.cancel()
        
        let releaseStart = Date()
        let bufferCount = allocatedBuffers.count
        let totalBytes = totalAllocated
        
        // Release all buffers
        for bufferId in allocatedBuffers.keys {
            try? await releaseBuffer(bufferId)
        }
        
        let releaseDuration = Date().timeIntervalSince(releaseStart)
        
        // Record bulk release metrics
        await recordCounter(.releaseCount, value: Double(bufferCount), tags: [
            "type": "bulk",
            "bytes": String(totalBytes)
        ])
        await recordLatency(.releaseDuration, seconds: releaseDuration, tags: ["type": "bulk"])
        await recordGauge(.bufferCount, value: 0)
        await recordGauge(.usageBytes, value: 0)
        
        allocatedBuffers.removeAll()
        totalAllocated = 0
        state = .idle
    }
    
    /// Returns current memory allocation statistics.
    public func currentStats() -> MemoryStats {
        MemoryStats(
            allocatedBuffers: allocatedBuffers.count,
            totalAllocated: totalAllocated,
            largestBuffer: allocatedBuffers.values.map(\.size).max() ?? 0,
            averageBufferSize: allocatedBuffers.isEmpty ? 0 : totalAllocated / allocatedBuffers.count
        )
    }
    
    // MARK: - Private Methods
    
    private func performGradualPressure(
        _ targetUsage: Double,
        _ duration: TimeInterval,
        _ stepSize: Int = 10_000_000
    ) async throws {
        let totalMemory = SystemInfo.totalMemory()
        let targetBytes = Int(Double(totalMemory) * targetUsage)
        let currentUsage = SystemInfo.currentMemoryUsage()
        let additionalNeeded = max(0, targetBytes - currentUsage)
        
        guard additionalNeeded > 0 else { return }
        
        let steps = max(1, additionalNeeded / stepSize)
        let stepDuration = duration / Double(steps)
        let actualStepSize = additionalNeeded / steps
        
        for i in 0..<steps {
            try Task.checkCancellation()
            
            let stepStart = Date()
            
            // Check safety before each allocation
            guard await safetyMonitor.canAllocateMemory(actualStepSize) else {
                throw SimulatorError.safetyLimitExceeded(
                    requested: actualStepSize,
                    reason: "Gradual pressure would exceed safety limits"
                )
            }
            
            let buffer = try await allocateBuffer(size: actualStepSize)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += actualStepSize
            
            // Record allocation metrics
            let allocationTime = Date().timeIntervalSince(stepStart)
            await recordLatency(.allocationLatency, seconds: allocationTime, tags: [
                "pattern": "gradual",
                "step": String(i + 1),
                "total_steps": String(steps)
            ])
            
            // Record current memory usage
            let currentUsagePercent = Double(SystemInfo.currentMemoryUsage()) / Double(totalMemory)
            await recordUsageLevel(.usagePercentage, percentage: currentUsagePercent)
            await recordGauge(.usageBytes, value: Double(totalAllocated))
            
            try await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
        }
    }
    
    private func releaseToUsage(_ targetUsage: Double, duration: TimeInterval) async throws {
        let totalMemory = SystemInfo.totalMemory()
        let targetBytes = Int(Double(totalMemory) * targetUsage)
        let currentUsage = SystemInfo.currentMemoryUsage()
        let toRelease = max(0, currentUsage - targetBytes)
        
        guard toRelease > 0 else { return }
        
        let releaseStart = Date()
        
        // Record release phase start
        await recordGauge(.releaseCount, value: 1.0, tags: [
            "phase": "started",
            "target_usage": String(targetUsage),
            "bytes_to_release": String(toRelease)
        ])
        
        // Sort buffers by size (release largest first)
        let sortedBuffers = allocatedBuffers.values.sorted { $0.size > $1.size }
        var released = 0
        var buffersReleased = 0
        
        for buffer in sortedBuffers {
            if released >= toRelease { break }
            
            try await releaseBuffer(buffer.id)
            released += buffer.size
            buffersReleased += 1
            
            // Record release progress
            let progressPercent = min(100, Int(Double(released) / Double(toRelease) * 100))
            await recordGauge(.releaseCount, value: Double(progressPercent), tags: [
                "metric": "progress",
                "buffers_released": String(buffersReleased),
                "bytes_released": String(released)
            ])
            
            // Small delay to make release gradual
            try await Task.sleep(nanoseconds: UInt64(duration / Double(sortedBuffers.count) * 1_000_000_000))
        }
        
        let releaseDuration = Date().timeIntervalSince(releaseStart)
        
        // Record release phase completion
        await recordCounter(.releaseCount, value: 1.0, tags: [
            "phase": "completed",
            "buffers_released": String(buffersReleased),
            "bytes_released": String(released),
            "duration": String(releaseDuration)
        ])
        await recordPressureLevel()
    }
    
    private func allocateBuffer(size: Int) async throws -> AllocatedBuffer {
        let allocationStart = Date()
        
        // Use resource manager to allocate tracked memory
        let managedBuffer = try await resourceManager.allocateMemory(size: size)
        
        // Fill with pattern to ensure pages are committed
        managedBuffer.pointer.initializeMemory(
            as: UInt8.self,
            repeating: 0xAB,
            count: size
        )
        
        let allocationTime = Date().timeIntervalSince(allocationStart)
        allocationCount += 1
        
        // Record allocation metrics
        await recordCounter(.allocationCount)
        await recordHistogram(.allocationSize, value: Double(size))
        await recordLatency(.allocationDuration, seconds: allocationTime)
        await recordGauge(.bufferCount, value: Double(allocatedBuffers.count + 1))
        
        return AllocatedBuffer(
            id: managedBuffer.id,
            size: size,
            managedBuffer: managedBuffer
        )
    }
    
    private func releaseBuffer(_ id: UUID) async throws {
        guard let buffer = allocatedBuffers.removeValue(forKey: id) else { return }
        
        let releaseStart = Date()
        totalAllocated -= buffer.size
        releaseCount += 1
        
        try await resourceManager.release(buffer.managedBuffer.id)
        
        let releaseTime = Date().timeIntervalSince(releaseStart)
        let bufferLifetime = Date().timeIntervalSince(buffer.allocatedAt)
        
        // Record release metrics
        await recordCounter(.releaseCount)
        await recordLatency(.releaseDuration, seconds: releaseTime)
        await recordHistogram(.bufferLifetime, value: bufferLifetime)
        await recordGauge(.bufferCount, value: Double(allocatedBuffers.count))
        await recordGauge(.usageBytes, value: Double(totalAllocated))
    }
    
    // MARK: - Metrics Recording
    
    /// Records current memory pressure level
    private func recordPressureLevel() async {
        let totalMemory = SystemInfo.totalMemory()
        let currentUsage = SystemInfo.currentMemoryUsage()
        let usagePercent = Double(currentUsage) / Double(totalMemory) * 100
        
        await recordGauge(.pressureLevel, value: usagePercent, tags: [
            "state": String(describing: state)
        ])
        
        // Categorize pressure level
        let level: String
        switch usagePercent {
        case 0..<50: level = "low"
        case 50..<70: level = "moderate"
        case 70..<85: level = "high"
        default: level = "critical"
        }
        
        await recordGauge(.pressureLevel, value: 1.0, tags: [
            "category": level
        ])
    }
}

// MARK: - Supporting Types

/// Represents an allocated memory buffer.
private struct AllocatedBuffer {
    let id: UUID
    let size: Int
    let managedBuffer: ManagedBuffer
    let allocatedAt = Date()
}

/// Memory allocation statistics.
public struct MemoryStats: Sendable {
    public let allocatedBuffers: Int
    public let totalAllocated: Int
    public let largestBuffer: Int
    public let averageBufferSize: Int
}

/// Errors specific to memory simulation.
public enum SimulatorError: LocalizedError {
    case invalidState(current: MemoryPressureSimulator.State, expected: MemoryPressureSimulator.State)
    case safetyLimitExceeded(requested: Int, reason: String)
    case allocationFailed(size: Int, error: Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidState(let current, let expected):
            return "Invalid simulator state: \(current), expected \(expected)"
        case .safetyLimitExceeded(let requested, let reason):
            return "Safety limit exceeded: requested \(requested) bytes - \(reason)"
        case .allocationFailed(let size, let error):
            return "Failed to allocate \(size) bytes: \(error)"
        }
    }
}

// MARK: - Convenience Extensions

public extension MemoryPressureSimulator {
    /// Creates memory fragmentation by allocating many small buffers.
    func createFragmentation(
        totalSize: Int,
        fragmentCount: Int
    ) async throws {
        let fragmentSize = totalSize / fragmentCount
        
        // Record fragmentation start
        await recordGauge(.fragmentationProgress, value: 0.0, tags: [
            "phase": "started",
            "total_size": String(totalSize),
            "fragment_count": String(fragmentCount),
            "fragment_size": String(fragmentSize)
        ])
        
        let fragmentationStart = Date()
        var successfulFragments = 0
        
        for i in 0..<fragmentCount {
            try Task.checkCancellation()
            
            guard await safetyMonitor.canAllocateMemory(fragmentSize) else {
                await recordSafetyRejection(.safetyRejection,
                    reason: "Fragmentation would exceed safety limits",
                    requested: String(fragmentSize),
                    tags: [
                        "pattern": "fragmentation",
                        "fragment": String(i + 1),
                        "successful_fragments": String(successfulFragments)
                    ])
                
                throw SimulatorError.safetyLimitExceeded(
                    requested: fragmentSize,
                    reason: "Fragmentation would exceed safety limits"
                )
            }
            
            let buffer = try await allocateBuffer(size: fragmentSize)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += fragmentSize
            successfulFragments += 1
            
            // Record fragmentation progress
            if (i + 1) % 10 == 0 || i == fragmentCount - 1 {
                await recordGauge(.fragmentationProgress, value: Double(i + 1), tags: [
                    "total_fragments": String(fragmentCount),
                    "percent_complete": String(Int(Double(i + 1) / Double(fragmentCount) * 100))
                ])
            }
            
            // Small delay between allocations
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        
        let fragmentationDuration = Date().timeIntervalSince(fragmentationStart)
        
        // Record fragmentation completion
        await recordCounter(.allocationCount, value: Double(successfulFragments), tags: [
            "pattern": "fragmentation",
            "phase": "completed",
            "duration": String(fragmentationDuration)
        ])
        await recordHistogram(.allocationDuration, value: fragmentationDuration, tags: ["pattern": "fragmentation"])
        await recordPressureLevel()
    }
    
    /// Simulates memory leak by gradually increasing allocations.
    func simulateLeak(
        rate: Int,  // Bytes per second
        duration: TimeInterval
    ) async throws {
        let interval: TimeInterval = 1.0  // Leak every second
        let iterations = Int(duration / interval)
        
        // Record leak simulation start
        await recordGauge(.leakTotal, value: 0.0, tags: [
            "phase": "started",
            "rate_bytes_per_sec": String(rate),
            "duration": String(duration)
        ])
        
        for i in 0..<iterations {
            try Task.checkCancellation()
            
            guard await safetyMonitor.canAllocateMemory(rate) else {
                await recordSafetyRejection(.safetyRejection,
                    reason: "Leak simulation would exceed safety limits",
                    requested: String(rate),
                    tags: [
                        "pattern": "leak",
                        "iteration": String(i),
                        "total_leaked": String(totalAllocated)
                    ])
                
                throw SimulatorError.safetyLimitExceeded(
                    requested: rate,
                    reason: "Leak simulation would exceed safety limits"
                )
            }
            
            let buffer = try await allocateBuffer(size: rate)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += rate
            
            // Record leak metrics
            await recordCounter(.allocationCount, tags: ["pattern": "leak"])
            await recordGauge(.leakTotal, value: Double(totalAllocated))
            await recordGauge(.leakIteration, value: Double(i + 1))
            await recordPressureLevel()
            
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        
        // Record leak simulation completion
        await recordCounter(.allocationCount, value: Double(iterations), tags: [
            "pattern": "leak",
            "phase": "completed",
            "total_leaked_bytes": String(totalAllocated)
        ])
    }
}