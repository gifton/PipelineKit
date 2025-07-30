import Foundation
@testable import PipelineKit

/// A scenario that executes multiple phases in sequence.
///
/// MultiPhaseScenario allows you to build complex test scenarios that progress
/// through distinct phases, with transitions and validations between each phase.
///
/// ## Example
/// ```swift
/// let scenario = MultiPhaseScenario(name: "Load Test")
///     .addPhase("Ramp Up") { context in
///         // Gradually increase load
///     }
///     .addPhase("Sustain", duration: 60) { context in
///         // Maintain steady load
///     }
///     .addPhase("Cool Down") { context in
///         // Reduce load to baseline
///     }
///     .withTransition { from, to in
///         // Validate transition conditions
///     }
/// ```
public struct MultiPhaseScenario: StressScenario {
    
    // MARK: - Types
    
    /// A single phase in the scenario
    public struct Phase {
        public let name: String
        public let duration: TimeInterval?
        public let execute: (TestContext) async throws -> Void
        public let validate: ((PhaseResult) -> Bool)?
        
        public init(
            name: String,
            duration: TimeInterval? = nil,
            execute: @escaping (TestContext) async throws -> Void,
            validate: ((PhaseResult) -> Bool)? = nil
        ) {
            self.name = name
            self.duration = duration
            self.execute = execute
            self.validate = validate
        }
    }
    
    /// Result of executing a phase
    public struct PhaseResult {
        public let phase: String
        public let startTime: Date
        public let endTime: Date
        public let duration: TimeInterval
        public let metrics: [String: Any]
        public let success: Bool
        public let error: Error?
        
        public var passed: Bool {
            success && error == nil
        }
    }
    
    /// Transition handler between phases
    public typealias TransitionHandler = (PhaseResult, Phase) async throws -> Bool
    
    // MARK: - Properties
    
    public let name: String
    public var description: String { name }
    public var timeout: TimeInterval {
        phases.reduce(300.0) { total, phase in
            total + (phase.duration ?? 60.0)
        }
    }
    public var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    private var phases: [Phase] = []
    private var transitionHandler: TransitionHandler?
    private var phaseResults: [PhaseResult] = []
    private let testContext: TestContext?
    
    // MARK: - Initialization
    
    public init(name: String, testContext: TestContext? = nil) {
        self.name = name
        self.testContext = testContext
    }
    
    // MARK: - Builder Methods
    
    /// Add a phase to the scenario
    @discardableResult
    public mutating func addPhase(
        _ name: String,
        duration: TimeInterval? = nil,
        execute: @escaping (TestContext) async throws -> Void
    ) -> Self {
        phases.append(Phase(
            name: name,
            duration: duration,
            execute: execute
        ))
        return self
    }
    
    /// Add a phase with validation
    @discardableResult
    public mutating func addPhase(
        _ name: String,
        duration: TimeInterval? = nil,
        execute: @escaping (TestContext) async throws -> Void,
        validate: @escaping (PhaseResult) -> Bool
    ) -> Self {
        phases.append(Phase(
            name: name,
            duration: duration,
            execute: execute,
            validate: validate
        ))
        return self
    }
    
    /// Set transition handler
    @discardableResult
    public mutating func withTransition(
        _ handler: @escaping TransitionHandler
    ) -> Self {
        self.transitionHandler = handler
        return self
    }
    
    // MARK: - StressScenario Implementation
    
    public func setUp() async throws {
        phaseResults.removeAll()
    }
    
    public func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        guard let context = testContext else {
            throw TestError.configuration("MultiPhaseScenario requires TestContext")
        }
        
        for (index, phase) in phases.enumerated() {
            // Check for cancellation before each phase
            try Task.checkCancellation()
            
            // Log phase start
            testLogger.info("Starting phase \(index + 1)/\(phases.count): \(phase.name)")
            
            // Check if we can transition (except for first phase)
            if index > 0, let transition = transitionHandler {
                let previousResult = phaseResults[index - 1]
                let canTransition = try await transition(previousResult, phase)
                if !canTransition {
                    throw TestError.phaseTransition(
                        from: previousResult.phase,
                        to: phase.name,
                        reason: "Transition validation failed"
                    )
                }
            }
            
            // Execute phase
            let startTime = Date()
            let startMetrics = await metricCollector.snapshot()
            var phaseError: Error?
            
            do {
                // Run with timeout if specified
                if let duration = phase.duration {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // Main execution
                        group.addTask {
                            try await phase.execute(context)
                        }
                        
                        // Timeout
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                            throw TestError.timeout(phase: phase.name, limit: duration)
                        }
                        
                        // First to complete wins
                        try await group.next()
                        group.cancelAll()
                    }
                } else {
                    try await phase.execute(context)
                }
            } catch {
                phaseError = error
                testLogger.error("Phase \(phase.name) failed", error: error)
            }
            
            // Capture end metrics
            let endTime = Date()
            let endMetrics = await metricCollector.snapshot()
            
            // Create phase result
            let result = PhaseResult(
                phase: phase.name,
                startTime: startTime,
                endTime: endTime,
                duration: endTime.timeIntervalSince(startTime),
                metrics: endMetrics.metrics,
                success: phaseError == nil,
                error: phaseError
            )
            
            phaseResults.append(result)
            
            // Validate phase if validator provided
            if let validator = phase.validate {
                let isValid = validator(result)
                if !isValid {
                    throw TestError.phaseValidation(
                        phase: phase.name,
                        reason: "Phase validation failed"
                    )
                }
            }
            
            // Stop on error unless we want to continue
            if phaseError != nil {
                throw phaseError!
            }
            
            testLogger.info("Completed phase \(phase.name) in \(String(format: "%.2fs", result.duration))")
        }
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        // This method is required by the protocol but we need the full context
        throw TestError.unsupported("Use execute(orchestrator:safetyMonitor:metricCollector:) instead")
    }
    
    public func tearDown() async throws {
        // Log phase summary
        testLogger.info("Multi-phase scenario completed:")
        for result in phaseResults {
            let status = result.passed ? "✓" : "✗"
            testLogger.info("  \(status) \(result.phase): \(String(format: "%.2fs", result.duration))")
        }
    }
    
    // MARK: - Results Access
    
    /// Get results for all completed phases
    public func getPhaseResults() -> [PhaseResult] {
        phaseResults
    }
    
    /// Get result for a specific phase
    public func getPhaseResult(named name: String) -> PhaseResult? {
        phaseResults.first { $0.phase == name }
    }
}

// MARK: - Test Error Extensions

extension TestError {
    static func phaseTransition(from: String, to: String, reason: String) -> TestError {
        TestError(message: "Phase transition failed from '\(from)' to '\(to)': \(reason)")
    }
    
    static func phaseValidation(phase: String, reason: String) -> TestError {
        TestError(message: "Phase '\(phase)' validation failed: \(reason)")
    }
    
    static func timeout(phase: String, limit: TimeInterval) -> TestError {
        TestError(message: "Phase '\(phase)' timed out after \(limit)s")
    }
}

// MARK: - Example Scenarios

public extension MultiPhaseScenario {
    
    /// Creates a standard load test scenario
    static func loadTest(
        name: String = "Load Test",
        rampUpDuration: TimeInterval = 30,
        sustainDuration: TimeInterval = 120,
        coolDownDuration: TimeInterval = 30,
        targetLoad: Int = 100
    ) -> MultiPhaseScenario {
        var scenario = MultiPhaseScenario(name: name)
        
        // Ramp up phase
        scenario.addPhase("Ramp Up", duration: rampUpDuration) { context in
            let steps = Int(rampUpDuration)
            for i in 0..<steps {
                try Task.checkCancellation()
                
                let currentLoad = (i + 1) * targetLoad / steps
                testLogger.debug("Ramping up to \(currentLoad) concurrent operations")
                
                // Simulate increasing load
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        
        // Sustain phase
        scenario.addPhase("Sustain", duration: sustainDuration) { context in
            testLogger.info("Sustaining \(targetLoad) concurrent operations")
            
            // Maintain steady load
            try await Task.sleep(nanoseconds: UInt64(sustainDuration * 1_000_000_000))
        }
        
        // Cool down phase
        scenario.addPhase("Cool Down", duration: coolDownDuration) { context in
            let steps = Int(coolDownDuration)
            for i in 0..<steps {
                try Task.checkCancellation()
                
                let currentLoad = targetLoad - (i * targetLoad / steps)
                testLogger.debug("Reducing to \(currentLoad) concurrent operations")
                
                // Simulate decreasing load
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        
        // Add transition validation
        scenario.withTransition { previousResult, nextPhase in
            // Ensure previous phase completed successfully
            guard previousResult.passed else {
                testLogger.warning("Cannot transition to \(nextPhase.name): previous phase failed")
                return false
            }
            
            // Additional validation could go here
            return true
        }
        
        return scenario
    }
    
    /// Creates a stress test scenario with recovery phases
    static func stressTestWithRecovery(
        name: String = "Stress Test with Recovery",
        stressDuration: TimeInterval = 60,
        recoveryDuration: TimeInterval = 30,
        cycles: Int = 3
    ) -> MultiPhaseScenario {
        var scenario = MultiPhaseScenario(name: name)
        
        for cycle in 0..<cycles {
            // Stress phase
            scenario.addPhase("Stress Cycle \(cycle + 1)", duration: stressDuration) { context in
                testLogger.info("Applying stress load for cycle \(cycle + 1)")
                
                // Simulate heavy load
                try await Task.sleep(nanoseconds: UInt64(stressDuration * 1_000_000_000))
            }
            
            // Recovery phase
            scenario.addPhase("Recovery Cycle \(cycle + 1)", duration: recoveryDuration) { context in
                testLogger.info("Recovery period for cycle \(cycle + 1)")
                
                // Allow system to recover
                try await Task.sleep(nanoseconds: UInt64(recoveryDuration * 1_000_000_000))
            }
        }
        
        return scenario
    }
}