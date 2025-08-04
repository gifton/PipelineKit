import Foundation
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: These types require PipelineKitStressTest types which have been
// moved to a separate package. They should be moved to that package's test suite.

// Placeholder types to prevent compilation errors
public struct TypedMetrics {}
// SafetyMonitor is defined in MockSafetyMonitor.swift
// MetricCollector is defined elsewhere
public struct TestError: Error {
    let message: String
    init(message: String) { self.message = message }
    static func configuration(_ msg: String) -> TestError { TestError(message: msg) }
    static func phaseTransition(from: String, to: String, reason: String) -> TestError { 
        TestError(message: "Phase transition failed from '\(from)' to '\(to)': \(reason)")
    }
    static func timeout(phase: String, limit: TimeInterval) -> TestError {
        TestError(message: "Phase '\(phase)' timed out after \(limit) seconds")
    }
    static func phaseValidation(phase: String, reason: String) -> TestError {
        TestError(message: "Phase '\(phase)' validation failed: \(reason)")
    }
    static func unsupported(_ msg: String) -> TestError { TestError(message: msg) }
}
public protocol StressOrchestrator {}
public struct testLogger {
    static func info(_ msg: String) {}
    static func error(_ msg: String, error: Error) {}
}

// Minimal placeholder scenario
public struct MultiPhaseScenario {
    public var name: String
    public var timeout: TimeInterval = 300
    public var description: String { name }
    public var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    public init(name: String) {
        self.name = name
    }
    
    public func setUp() async throws {}
    public func execute(context: StressContext) async throws {}
    public func tearDown() async throws {}
}

/*
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
    
    /// Result from executing a phase
    public struct PhaseResult {
        public let phase: String
        public let startTime: Date
        public let endTime: Date
        public let duration: TimeInterval
        public let metrics: TypedMetrics
        public let success: Bool
        public let error: Error?
        
        public init(
            phase: String,
            startTime: Date,
            endTime: Date,
            metrics: TypedMetrics,
            success: Bool,
            error: Error? = nil
        ) {
            self.phase = phase
            self.startTime = startTime
            self.endTime = endTime
            self.duration = endTime.timeIntervalSince(startTime)
            self.metrics = metrics
            self.success = success
            self.error = error
        }
    }
    
    // MARK: - Properties
    
    public let name: String
    public var description: String { 
        "\(name) - \(phases.count) phases"
    }
    public var timeout: TimeInterval { 
        phases.compactMap { $0.duration }.reduce(300, +) 
    }
    public var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    private var phases: [Phase] = []
    private var transitionHandler: ((PhaseResult, Phase) async throws -> Bool)?
    private var phaseResults: [PhaseResult] = []
    private var testContext: TestContext?
    
    // MARK: - Initialization
    
    public init(name: String) {
        self.name = name
    }
    
    // MARK: - Configuration
    
    /// Add a phase to the scenario
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
    public mutating func addPhase(
        _ name: String,
        duration: TimeInterval? = nil,
        validate: @escaping (PhaseResult) -> Bool,
        execute: @escaping (TestContext) async throws -> Void
    ) -> Self {
        phases.append(Phase(
            name: name,
            duration: duration,
            execute: execute,
            validate: validate
        ))
        return self
    }
    
    /// Set transition validation between phases
    public mutating func withTransition(
        _ handler: @escaping (PhaseResult, Phase) async throws -> Bool
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
        
        // Execute each phase in sequence
        for (index, phase) in phases.enumerated() {
            let phaseNumber = index + 1
            
            // Log phase start
            testLogger.info("Starting phase \(index + 1)/\(phases.count): \(phase.name)")
            
            // Check if we can transition (except for first phase)
            if index > 0 {
                let previousResult = phaseResults[index - 1]
                let transition = transitionHandler ?? { _, _ in true }
                let canTransition = try await transition(previousResult, phase)
                if !canTransition {
                    throw TestError.phaseTransition(
                        from: previousResult.phase,
                        to: phase.name,
                        reason: "Transition validation failed"
                    )
                }
            }
            
            // Execute the phase
            let startTime = Date()
            var phaseError: Error?
            
            do {
                // If phase has a duration, enforce timeout
                if let duration = phase.duration {
                    // Run phase with timeout
                    try await withTimeout(seconds: duration) {
                        // Create a task group to run phase and monitor timeout
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            // Main phase execution
                            group.addTask {
                                try await phase.execute(context)
                            }
                            
                            // Timeout monitoring
                            group.addTask {
                                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                                throw TestError.timeout(phase: phase.name, limit: duration)
                            }
                            
                            // Wait for first to complete (either phase or timeout)
                            _ = try await group.next()
                            group.cancelAll()
                        }
                    }
                } else {
                    // No timeout specified
                    try await phase.execute(context)
                }
            } catch {
                phaseError = error
                testLogger.error("Phase \(phase.name) failed", error: error)
            }
            
            let endTime = Date()
            
            // Collect metrics for the phase
            
            // Create phase result
            var typedMetrics = TypedMetrics()
            // For now, we'll store the duration as a metric
            typedMetrics.set(.executionTime, value: .duration(endTime.timeIntervalSince(startTime)))
            
            let result = PhaseResult(
                phase: phase.name,
                startTime: startTime,
                endTime: endTime,
                metrics: typedMetrics,
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
            
            // If phase failed, stop execution
            if !result.success {
                throw phaseError ?? TestError.phaseValidation(
                    phase: phase.name, 
                    reason: "Phase execution failed"
                )
            }
            
            testLogger.info("Completed phase \(phase.name) in \(String(format: "%.2fs", result.duration))")
        }
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        // This method is required by the protocol but we need the full context
        throw TestError.unsupported("Use execute(orchestrator:safetyMonitor:metricCollector:) instead")
    }
    
    public func tearDown() async throws {
        // Clean up any resources
        phaseResults.removeAll()
        testContext = nil
    }
    
    // MARK: - Helper Methods
    
    /// Get all phase results
    public func getResults() -> [PhaseResult] {
        return phaseResults
    }
    
    /// Get result for a specific phase
    public func getResult(for phaseName: String) -> PhaseResult? {
        return phaseResults.first { $0.phase == phaseName }
    }
    
    /// Set the test context (for internal use)
    public mutating func setContext(_ context: TestContext) {
        self.testContext = context
    }
}

// MARK: - Test Error Extensions

extension TestError {
    static func phaseTransition(from: String, to: String, reason: String) -> TestError {
        TestError(message: "Phase transition failed from '\(from)' to '\(to)': \(reason)")
    }
    
    static func timeout(phase: String, limit: TimeInterval) -> TestError {
        TestError(message: "Phase '\(phase)' timed out after \(limit) seconds")
    }
    
    static func phaseValidation(phase: String, reason: String) -> TestError {
        TestError(message: "Phase '\(phase)' validation failed: \(reason)")
    }
}

// MARK: - Timeout Helper

private func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw PipelineError.cancelled(context: nil)
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
*/