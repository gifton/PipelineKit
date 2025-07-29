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
public actor MemoryPressureSimulator {
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
    private(set) var state: State = .idle
    
    /// Currently allocated buffers.
    private var allocatedBuffers: [UUID: AllocatedBuffer] = [:]
    
    /// Total allocated memory.
    private var totalAllocated: Int = 0
    
    /// Active pressure task.
    private var pressureTask: Task<Void, Error>?
    
    public init(
        resourceManager: ResourceManager,
        safetyMonitor: any SafetyMonitor
    ) {
        self.resourceManager = resourceManager
        self.safetyMonitor = safetyMonitor
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
        
        state = .applying(pattern: .gradual(targetUsage: targetUsage, duration: duration))
        pressureTask = Task { try await performGradualPressure(targetUsage, duration, stepSize) }
        
        do {
            try await pressureTask!.value
            state = .idle
        } catch {
            state = .idle
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
        
        // Check safety before allocation
        guard await safetyMonitor.canAllocateMemory(size) else {
            throw SimulatorError.safetyLimitExceeded(
                requested: size,
                reason: "Memory allocation would exceed safety limits"
            )
        }
        
        state = .applying(pattern: .burst(size: size, count: 1))
        
        do {
            // Allocate memory
            let buffer = try await allocateBuffer(size: size)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += size
            
            state = .holding(size: size)
            
            // Hold for specified time
            try await Task.sleep(nanoseconds: UInt64(holdTime * 1_000_000_000))
            
            // Release
            state = .releasing
            try await releaseBuffer(buffer.id)
            
            state = .idle
        } catch {
            state = .idle
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
        
        state = .applying(pattern: .oscillating(minUsage: minUsage, maxUsage: maxUsage, period: period))
        
        pressureTask = Task {
            for _ in 0..<cycles {
                try Task.checkCancellation()
                
                // Ramp up to max
                try await performGradualPressure(maxUsage, period / 2)
                
                // Ramp down to min
                try await releaseToUsage(minUsage, duration: period / 2)
            }
        }
        
        do {
            try await pressureTask!.value
            state = .idle
        } catch {
            state = .idle
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
        
        state = .applying(pattern: .stepped(steps: steps, holdTime: holdTime))
        
        pressureTask = Task {
            for step in steps {
                try Task.checkCancellation()
                
                // Reach target
                try await performGradualPressure(step, 2.0)  // 2 seconds to reach each step
                
                // Hold
                try await Task.sleep(nanoseconds: UInt64(holdTime * 1_000_000_000))
            }
        }
        
        do {
            try await pressureTask!.value
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }
    
    /// Releases all allocated memory.
    public func releaseAll() async {
        state = .releasing
        pressureTask?.cancel()
        
        // Release all buffers
        for bufferId in allocatedBuffers.keys {
            try? await releaseBuffer(bufferId)
        }
        
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
        
        for _ in 0..<steps {
            try Task.checkCancellation()
            
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
            
            try await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
        }
    }
    
    private func releaseToUsage(_ targetUsage: Double, duration: TimeInterval) async throws {
        let totalMemory = SystemInfo.totalMemory()
        let targetBytes = Int(Double(totalMemory) * targetUsage)
        let currentUsage = SystemInfo.currentMemoryUsage()
        let toRelease = max(0, currentUsage - targetBytes)
        
        guard toRelease > 0 else { return }
        
        // Sort buffers by size (release largest first)
        let sortedBuffers = allocatedBuffers.values.sorted { $0.size > $1.size }
        var released = 0
        
        for buffer in sortedBuffers {
            if released >= toRelease { break }
            
            try await releaseBuffer(buffer.id)
            released += buffer.size
            
            // Small delay to make release gradual
            try await Task.sleep(nanoseconds: UInt64(duration / Double(sortedBuffers.count) * 1_000_000_000))
        }
    }
    
    private func allocateBuffer(size: Int) async throws -> AllocatedBuffer {
        // Use resource manager to allocate tracked memory
        let managedBuffer = try await resourceManager.allocateMemory(size: size)
        
        // Fill with pattern to ensure pages are committed
        managedBuffer.pointer.initializeMemory(
            as: UInt8.self,
            repeating: 0xAB,
            count: size
        )
        
        return AllocatedBuffer(
            id: managedBuffer.id,
            size: size,
            managedBuffer: managedBuffer
        )
    }
    
    private func releaseBuffer(_ id: UUID) async throws {
        guard let buffer = allocatedBuffers.removeValue(forKey: id) else { return }
        
        totalAllocated -= buffer.size
        try await resourceManager.release(buffer.managedBuffer.id)
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
        
        for _ in 0..<fragmentCount {
            try Task.checkCancellation()
            
            guard await safetyMonitor.canAllocateMemory(fragmentSize) else {
                throw SimulatorError.safetyLimitExceeded(
                    requested: fragmentSize,
                    reason: "Fragmentation would exceed safety limits"
                )
            }
            
            let buffer = try await allocateBuffer(size: fragmentSize)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += fragmentSize
            
            // Small delay between allocations
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }
    
    /// Simulates memory leak by gradually increasing allocations.
    func simulateLeak(
        rate: Int,  // Bytes per second
        duration: TimeInterval
    ) async throws {
        let interval: TimeInterval = 1.0  // Leak every second
        let iterations = Int(duration / interval)
        
        for _ in 0..<iterations {
            try Task.checkCancellation()
            
            guard await safetyMonitor.canAllocateMemory(rate) else {
                throw SimulatorError.safetyLimitExceeded(
                    requested: rate,
                    reason: "Leak simulation would exceed safety limits"
                )
            }
            
            let buffer = try await allocateBuffer(size: rate)
            allocatedBuffers[buffer.id] = buffer
            totalAllocated += rate
            
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}