import Foundation

/// Protocol defining a stress test scenario.
public protocol StressScenario: Sendable {
    /// Unique name for the scenario.
    var name: String { get }
    
    /// Timeout for the scenario.
    var timeout: TimeInterval { get }
    
    /// Resource requirements for the scenario.
    var requiredResources: ResourceRequirements { get }
    
    /// Sets up the scenario before execution.
    func setUp() async throws
    
    /// Executes the scenario using the provided orchestrator.
    func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws
    
    /// Executes the scenario with orchestrator.
    func execute(with orchestrator: StressOrchestrator) async throws
    
    /// Tears down the scenario after execution.
    func tearDown() async throws
}

/// Resource requirements for scenarios.
public struct ResourceRequirements: Sendable {
    public let memory: Int?
    public let cpuCores: Int?
    public let diskSpace: Int?
    
    public init(
        memory: Int? = nil,
        cpuCores: Int? = nil,
        diskSpace: Int? = nil
    ) {
        self.memory = memory
        self.cpuCores = cpuCores
        self.diskSpace = diskSpace
    }
    
    public static let none = ResourceRequirements()
}

/// Base implementation for stress scenarios with common functionality.
@MainActor
public class BaseScenario: StressScenario {
    public let name: String
    public let namespace = "scenario"
    public let metricCollector: MetricCollector?
    
    // Protocol requirements
    public let timeout: TimeInterval
    public let requiredResources: ResourceRequirements
    
    // Common timing parameters
    public let warmupDuration: TimeInterval
    public let cooldownDuration: TimeInterval
    public let safetyCheckInterval: TimeInterval
    
    public init(
        name: String,
        metricCollector: MetricCollector? = nil,
        timeout: TimeInterval = 300.0,
        requiredResources: ResourceRequirements = .none,
        warmupDuration: TimeInterval = 5.0,
        cooldownDuration: TimeInterval = 5.0,
        safetyCheckInterval: TimeInterval = 1.0
    ) {
        self.name = name
        self.metricCollector = metricCollector
        self.timeout = timeout
        self.requiredResources = requiredResources
        self.warmupDuration = warmupDuration
        self.cooldownDuration = cooldownDuration
        self.safetyCheckInterval = safetyCheckInterval
    }
    
    /// Sets up the scenario - can be overridden by subclasses.
    public func setUp() async throws {
        // Default implementation does nothing
    }
    
    /// Tears down the scenario - can be overridden by subclasses.
    public func tearDown() async throws {
        // Default implementation does nothing
    }
    
    /// Execute with orchestrator convenience method.
    public func execute(with orchestrator: StressOrchestrator) async throws {
        try await execute(
            orchestrator: orchestrator,
            safetyMonitor: orchestrator.safetyMonitor,
            metricCollector: orchestrator.metricCollector
        )
    }
    
    public final func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        // Use the passed metricCollector if our optional one is nil
        let activeCollector = self.metricCollector ?? metricCollector
        
        // Record scenario start
        await activeCollector.recordEvent("\(namespace).scenario.start", tags: ["scenario": name])
        
        // Warmup phase
        await activeCollector.recordGauge("\(namespace).scenario.phase", value: 1.0, tags: [
            "scenario": name,
            "phase": "warmup"
        ])
        try await sleepWithSafetyCheck(warmupDuration, safetyMonitor: safetyMonitor)
        
        // Main timeline execution
        await activeCollector.recordGauge("\(namespace).scenario.phase", value: 1.0, tags: [
            "scenario": name,
            "phase": "main"
        ])
        try await runTimeline(
            orchestrator: orchestrator,
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
        
        // Cooldown phase
        await activeCollector.recordGauge("\(namespace).scenario.phase", value: 1.0, tags: [
            "scenario": name,
            "phase": "cooldown"
        ])
        try await sleepWithSafetyCheck(cooldownDuration, safetyMonitor: safetyMonitor)
        
        // Record scenario end
        await activeCollector.recordEvent("\(namespace).scenario.end", tags: ["scenario": name])
    }
    
    /// Override this to implement the scenario's main timeline.
    open func runTimeline(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        fatalError("Subclasses must override runTimeline")
    }
    
    // MARK: - Metric Recording
    
    private func recordScenarioStart() async {
        await recordEvent("scenario.start", tags: ["scenario": name])
    }
    
    private func recordScenarioEnd() async {
        await recordEvent("scenario.end", tags: ["scenario": name])
    }
    
    private func recordPhase(_ phase: String) async {
        await recordGauge("scenario.phase", value: 1.0, tags: [
            "scenario": name,
            "phase": phase
        ])
    }
    
    // MARK: - Simple Metric Methods
    
    /// Records an event metric.
    public func recordEvent(_ metric: String, tags: [String: String] = [:]) async {
        await metricCollector?.recordEvent("\(namespace).\(metric)", tags: tags)
    }
    
    /// Records a gauge metric.
    public func recordGauge(_ metric: String, value: Double, tags: [String: String] = [:]) async {
        await metricCollector?.recordGauge("\(namespace).\(metric)", value: value, tags: tags)
    }
    
    // MARK: - Safety and Cancellation Support
    
    /// Sleeps for the specified duration while checking for safety violations and cancellation.
    public func sleepWithSafetyCheck(
        _ duration: TimeInterval,
        safetyMonitor: any SafetyMonitor
    ) async throws {
        let startTime = Date()
        var elapsed: TimeInterval = 0
        
        while elapsed < duration {
            // Check for cancellation
            try Task.checkCancellation()
            
            // Check safety status
            let safetyStatus = await safetyMonitor.currentStatus()
            if safetyStatus.criticalViolations > 0 {
                await metricCollector?.recordEvent("\(namespace).scenario.safety_abort", tags: [
                    "scenario": name,
                    "violations": String(safetyStatus.criticalViolations),
                    "elapsed": String(format: "%.2f", elapsed)
                ])
                throw ScenarioError.safetyViolation(
                    "Critical safety violations detected: \(safetyStatus.criticalViolations)"
                )
            }
            
            // Sleep for a slice of time (up to safety check interval)
            let remainingTime = duration - elapsed
            let sleepDuration = min(remainingTime, safetyCheckInterval)
            
            if sleepDuration > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
            
            elapsed = Date().timeIntervalSince(startTime)
        }
    }
}

/// Configuration for intensity ranges in scenarios.
public struct IntensityRange: Sendable {
    public let min: Double
    public let max: Double
    
    public init(min: Double = 0.0, max: Double = 1.0) {
        self.min = min
        self.max = max
    }
    
    public func random() -> Double {
        Double.random(in: min...max)
    }
    
    public func random(using generator: inout some RandomNumberGenerator) -> Double {
        Double.random(in: min...max, using: &generator)
    }
}

/// Scenario metrics namespace.
public enum ScenarioMetric: String {
    case scenarioStart = "scenario.start"
    case scenarioEnd = "scenario.end"
    case phaseStart = "phase.start"
    case phaseEnd = "phase.end"
    case simulatorScheduled = "simulator.scheduled"
    case intensityUpdate = "intensity.update"
    case safetyTriggered = "safety.triggered"
}