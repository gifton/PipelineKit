import Foundation
@testable import PipelineKit
import PipelineKitTestSupport
@testable import StressTesting

/// Thread-safe engine for scheduling and managing safety violations in tests.
///
/// ViolationSchedulingEngine provides deterministic scheduling of safety violations
/// with support for various trigger types and resource usage patterns.
actor ViolationSchedulingEngine {
    // MARK: - State
    
    /// Currently scheduled violations awaiting trigger
    private var scheduledViolations: [UUID: ScheduledViolationState] = [:]
    
    /// Active pattern simulations
    private var activePatterns: [UUID: PatternState] = [:]
    
    /// Historical record of all triggered violations
    private var violationHistory: [ViolationRecord] = []
    
    /// Maximum number of history records to retain
    private let maxHistorySize: Int
    
    /// Reference to time controller for deterministic scheduling
    private let timeController: TimeController
    
    /// Weak reference to the safety monitor we're controlling
    private weak var safetyMonitor: MockSafetyMonitor?
    
    // MARK: - Types
    
    /// Internal state for a scheduled violation
    private struct ScheduledViolationState {
        let violation: ScheduledViolation
        let task: Task<Void, Never>?
        var isActive: Bool
    }
    
    /// State for an active pattern simulation
    private struct PatternState {
        let violationId: UUID
        let pattern: ViolationPattern
        let type: TestDefaults.ViolationType
        let startTime: Date
        let duration: TimeInterval
        let updateTask: Task<Void, Never>?
        var lastUpdateTime: Date
    }
    
    // MARK: - Initialization
    
    init(
        timeController: TimeController,
        safetyMonitor: MockSafetyMonitor,
        maxHistorySize: Int = 1000
    ) {
        self.timeController = timeController
        self.safetyMonitor = safetyMonitor
        self.maxHistorySize = maxHistorySize
    }
    
    // MARK: - Scheduling
    
    /// Schedules a violation to occur based on the specified trigger
    func schedule(_ violation: ScheduledViolation) -> UUID {
        let task: Task<Void, Never>?
        
        switch violation.trigger {
        case .afterDelay(let delay):
            task = Task { [weak self] in
                await self?.timeController.wait(for: delay)
                await self?.triggerViolation(violation)
            }
            
        case .atTime(let date):
            let delay = date.timeIntervalSinceNow
            guard delay > 0 else {
                // Trigger immediately if time has passed
                Task { await triggerViolation(violation) }
                task = nil
                break
            }
            task = Task { [weak self] in
                await self?.timeController.wait(for: delay)
                await self?.triggerViolation(violation)
            }
            
        case .whenCondition(let condition):
            task = Task { [weak self] in
                while await self?.isViolationActive(violation.id) == true {
                    if await condition() {
                        await self?.triggerViolation(violation)
                        break
                    }
                    // Poll every 100ms
                    await self?.timeController.wait(for: 0.1)
                }
            }
            
        case .pattern(let pattern, let duration):
            // Validate pattern before scheduling
            do {
                try pattern.validate()
            } catch {
                // Log error and don't schedule
                print("Invalid pattern: \(error)")
                return violation.id
            }
            
            // Start pattern simulation
            startPatternSimulation(
                violationId: violation.id,
                pattern: pattern,
                type: violation.type,
                duration: duration
            )
            task = nil
        }
        
        // Store the scheduled violation
        scheduledViolations[violation.id] = ScheduledViolationState(
            violation: violation,
            task: task,
            isActive: true
        )
        
        return violation.id
    }
    
    /// Cancels a scheduled violation
    func cancel(_ id: UUID) -> Bool {
        guard let state = scheduledViolations[id], state.isActive else {
            return false
        }
        
        // Cancel any associated task
        state.task?.cancel()
        
        // Cancel any pattern simulation
        if let patternState = activePatterns[id] {
            patternState.updateTask?.cancel()
            activePatterns[id] = nil
        }
        
        // Mark as inactive
        scheduledViolations[id] = ScheduledViolationState(
            violation: state.violation,
            task: nil,
            isActive: false
        )
        
        return true
    }
    
    /// Cancels all pending violations
    func cancelAll() {
        // Cancel all scheduled violations
        for (id, state) in scheduledViolations where state.isActive {
            state.task?.cancel()
            scheduledViolations[id] = ScheduledViolationState(
                violation: state.violation,
                task: nil,
                isActive: false
            )
        }
        
        // Cancel all pattern simulations
        for (id, patternState) in activePatterns {
            patternState.updateTask?.cancel()
            activePatterns[id] = nil
        }
    }
    
    // MARK: - History
    
    /// Returns the history of all triggered violations
    func history() -> [ViolationRecord] {
        return violationHistory
    }
    
    /// Returns all currently pending violations
    func pendingViolations() -> [ScheduledViolation] {
        return scheduledViolations.values
            .filter { $0.isActive }
            .map { $0.violation }
    }
    
    // MARK: - Private Methods
    
    private func isViolationActive(_ id: UUID) -> Bool {
        return scheduledViolations[id]?.isActive ?? false
    }
    
    private func triggerViolation(_ violation: ScheduledViolation) async {
        guard isViolationActive(violation.id) else { return }
        
        // Mark as triggered
        scheduledViolations[violation.id]?.isActive = false
        
        // Apply the violation to the safety monitor
        await applySafetyViolation(type: violation.type, severity: violation.severity)
        
        // Create history record
        let record = ViolationRecord(
            scheduledViolationId: violation.id,
            type: violation.type,
            severity: violation.severity,
            triggerSource: "Scheduled",
            metadata: violation.metadata,
            stackTrace: Thread.callStackSymbols
        )
        
        addToHistory(record)
    }
    
    private func applySafetyViolation(
        type: TestDefaults.ViolationType,
        severity: ViolationSeverity
    ) async {
        guard let monitor = safetyMonitor else { return }
        
        // Map severity to resource usage levels
        let resourceLevel: Double = switch severity {
        case .warning: 0.75
        case .moderate: 0.85
        case .critical: 0.95
        case .emergency: 1.0
        }
        
        // Apply violation based on type
        switch type {
        case .memory:
            await monitor.setResourceUsage(memory: resourceLevel * 100)
        case .cpu:
            await monitor.setResourceUsage(cpu: resourceLevel * 100)
        case .fileDescriptor:
            let fdCount = Int(resourceLevel * Double(TestDefaults.SafetyLimits.maxFileDescriptors))
            await monitor.setResourceUsage(fileDescriptors: fdCount)
        case .custom:
            // For custom violations, trigger the violation flag
            await monitor.setViolationTrigger(true, count: 1)
        case .multiple:
            // For multiple violations, trigger both memory and CPU
            await monitor.setResourceUsage(memory: resourceLevel * 100)
            await monitor.setResourceUsage(cpu: resourceLevel * 100)
        }
        
        // Also trigger violation for critical and emergency
        if severity >= .critical {
            await monitor.setViolationTrigger(true, count: 1)
        }
    }
    
    private func startPatternSimulation(
        violationId: UUID,
        pattern: ViolationPattern,
        type: TestDefaults.ViolationType,
        duration: TimeInterval
    ) {
        let startTime = Date()
        
        let updateTask = Task { [weak self] in
            let updateInterval: TimeInterval = 0.1 // Update every 100ms
            var elapsed: TimeInterval = 0
            
            while elapsed < duration {
                guard await self?.isViolationActive(violationId) == true else { break }
                
                // Calculate pattern value
                let progress = elapsed / duration
                let value = await self?.calculatePatternValue(
                    pattern: pattern,
                    progress: progress,
                    elapsed: elapsed
                ) ?? 0
                
                // Apply the value
                await self?.applyPatternValue(value: value, type: type)
                
                // Wait for next update
                await self?.timeController.wait(for: updateInterval)
                elapsed += updateInterval
            }
            
            // Pattern completed, trigger the violation
            if let violation = await self?.scheduledViolations[violationId]?.violation {
                await self?.triggerViolation(violation)
            }
        }
        
        activePatterns[violationId] = PatternState(
            violationId: violationId,
            pattern: pattern,
            type: type,
            startTime: startTime,
            duration: duration,
            updateTask: updateTask,
            lastUpdateTime: startTime
        )
    }
    
    private func calculatePatternValue(
        pattern: ViolationPattern,
        progress: Double,
        elapsed: TimeInterval
    ) -> Double {
        switch pattern {
        case .gradual(let start, let end):
            // Linear interpolation
            return start + (end - start) * progress
            
        case .spike(let baseline, let peak, let at):
            // Spike at specific time
            let spikeWindow: TimeInterval = 0.5 // 500ms spike duration
            let distance = abs(elapsed - at)
            if distance < spikeWindow / 2 {
                // During spike
                let spikeProgress = 1.0 - (distance / (spikeWindow / 2))
                return baseline + (peak - baseline) * spikeProgress
            }
            return baseline
            
        case .oscillating(let min, let max, let period):
            // Sine wave oscillation
            let cycles = elapsed / period
            let phase = cycles * 2 * .pi
            let normalized = (sin(phase) + 1) / 2 // 0 to 1
            return min + (max - min) * normalized
            
        case .random(let range, let changeInterval):
            // Random within range, changing at intervals
            let seed = Int(elapsed / changeInterval)
            var generator = SeededRandomNumberGenerator(seed: seed)
            let random = Double.random(in: 0...1, using: &generator)
            return range.lowerBound + (range.upperBound - range.lowerBound) * random
            
        case .stepped(let levels):
            // Find current level based on elapsed time
            var accumulatedTime: TimeInterval = 0
            for level in levels {
                accumulatedTime += level.duration
                if elapsed < accumulatedTime {
                    return level.value
                }
            }
            // Return last level if beyond all durations
            return levels.last?.value ?? 0
        }
    }
    
    private func applyPatternValue(value: Double, type: TestDefaults.ViolationType) async {
        guard let monitor = safetyMonitor else { return }
        
        // Convert pattern value (0.0-1.0) to percentage (0-100)
        let percentage = value * 100
        
        switch type {
        case .memory:
            await monitor.setResourceUsage(memory: percentage)
        case .cpu:
            await monitor.setResourceUsage(cpu: percentage)
        case .fileDescriptor:
            let fdCount = Int(value * Double(TestDefaults.SafetyLimits.maxFileDescriptors))
            await monitor.setResourceUsage(fileDescriptors: fdCount)
        case .custom:
            // For custom, use value to determine if violation should trigger
            if value > 0.9 {
                await monitor.setViolationTrigger(true, count: 1)
            }
        case .multiple:
            // For multiple violations, apply both memory and CPU
            await monitor.setResourceUsage(memory: percentage)
            await monitor.setResourceUsage(cpu: percentage)
        }
    }
    
    private func addToHistory(_ record: ViolationRecord) {
        violationHistory.append(record)
        
        // Trim history if it exceeds max size
        if violationHistory.count > maxHistorySize {
            violationHistory.removeFirst(violationHistory.count - maxHistorySize)
        }
    }
}

// MARK: - Seeded Random Number Generator

/// Simple seeded random number generator for deterministic random patterns
private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var seed: UInt64
    
    init(seed: Int) {
        self.seed = UInt64(abs(seed))
    }
    
    mutating func next() -> UInt64 {
        seed = seed &* 2862933555777941757 &+ 3037000493
        return seed
    }
}
