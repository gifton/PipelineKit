import Foundation

/// Runner for executing stress test scenarios.
///
/// Provides a high-level interface for running scenarios with proper
/// setup, execution, and teardown handling.
public actor ScenarioRunner {
    private let orchestrator: StressOrchestrator
    private let safetyMonitor: any SafetyMonitor
    private let metricCollector: MetricCollector
    
    // Execution state
    private var currentScenario: (any StressScenario)?
    private var isRunning = false
    
    public init(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) {
        self.orchestrator = orchestrator
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
    }
    
    /// Runs a single scenario.
    public func run(_ scenario: any StressScenario) async throws {
        guard !isRunning else {
            throw ScenarioError.alreadyRunning
        }
        
        isRunning = true
        currentScenario = scenario
        
        defer {
            isRunning = false
            currentScenario = nil
        }
        
        // Record run start
        await metricCollector.recordEvent("scenario.run.start", tags: [
            "scenario": scenario.name
        ])
        
        let startTime = Date()
        
        do {
            // Execute scenario
            try await scenario.execute(
                orchestrator: orchestrator,
                safetyMonitor: safetyMonitor,
                metricCollector: metricCollector
            )
            
            // Record success
            let duration = Date().timeIntervalSince(startTime)
            await metricCollector.recordEvent("scenario.run.success", tags: [
                "scenario": scenario.name,
                "duration": String(format: "%.2f", duration)
            ])
            
        } catch {
            // Record failure
            let duration = Date().timeIntervalSince(startTime)
            await metricCollector.recordEvent("scenario.run.failure", tags: [
                "scenario": scenario.name,
                "duration": String(format: "%.2f", duration),
                "error": error.localizedDescription
            ])
            
            // Ensure cleanup
            await orchestrator.stopAll()
            
            throw error
        }
    }
    
    /// Runs multiple scenarios in sequence.
    public func runSequence(_ scenarios: [any StressScenario]) async throws {
        for (index, scenario) in scenarios.enumerated() {
            await metricCollector.recordEvent("scenario.sequence.progress", tags: [
                "current": String(index + 1),
                "total": String(scenarios.count),
                "scenario": scenario.name
            ])
            
            try await run(scenario)
            
            // Brief pause between scenarios
            if index < scenarios.count - 1 {
                // Use a simple sleep here since this is not part of a scenario
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
        }
    }
    
    /// Runs scenarios based on configuration.
    public func runFromConfiguration(_ config: ScenarioConfiguration) async throws {
        let scenarios = try await createScenarios(from: config)
        
        switch config.executionMode {
        case .sequential:
            try await runSequence(scenarios)
        case .single(let index):
            guard index < scenarios.count else {
                throw ScenarioError.invalidConfiguration("Scenario index out of range")
            }
            try await run(scenarios[index])
        }
    }
    
    /// Stops the currently running scenario.
    public func stop() async {
        guard isRunning else { return }
        
        await orchestrator.stopAll()
        
        if let scenario = currentScenario {
            await metricCollector.recordEvent("scenario.run.stopped", tags: [
                "scenario": scenario.name
            ])
        }
    }
    
    /// Gets the current execution status.
    public func status() async -> ScenarioStatus {
        ScenarioStatus(
            isRunning: isRunning,
            currentScenario: currentScenario?.name,
            orchestratorStatus: await orchestrator.currentStatus(),
            safetyStatus: await safetyMonitor.currentStatus()
        )
    }
    
    // MARK: - Private Helpers
    
    private func createScenarios(from config: ScenarioConfiguration) async throws -> [any StressScenario] {
        var scenarios: [any StressScenario] = []
        
        for scenarioConfig in config.scenarios {
            let scenario = try await createScenario(scenarioConfig)
            scenarios.append(scenario)
        }
        
        return scenarios
    }
    
    private func createScenario(_ config: ScenarioConfig) async throws -> any StressScenario {
        await MainActor.run {
        switch config.type {
        case .burst:
            return BurstLoadScenario(
                name: config.name ?? "BurstLoad",
                metricCollector: metricCollector,
                idleDuration: config.parameters["idleDuration"] as? TimeInterval ?? 10.0,
                spikeDuration: config.parameters["spikeDuration"] as? TimeInterval ?? 40.0,
                recoveryDuration: config.parameters["recoveryDuration"] as? TimeInterval ?? 20.0
            )
            
        case .sustained:
            return SustainedLoadScenario(
                name: config.name ?? "SustainedLoad",
                metricCollector: metricCollector,
                sustainedDuration: config.parameters["duration"] as? TimeInterval ?? 900.0
            )
            
        case .chaos:
            return ChaosScenario(
                name: config.name ?? "Chaos",
                metricCollector: metricCollector,
                totalDuration: config.parameters["duration"] as? TimeInterval ?? 300.0,
                seed: config.parameters["seed"] as? UInt64
            )
            
        case .rampUp:
            return RampUpScenario(
                name: config.name ?? "RampUp",
                metricCollector: metricCollector,
                startIntensity: config.parameters["startIntensity"] as? Double ?? 0.1,
                endIntensity: config.parameters["endIntensity"] as? Double ?? 0.95,
                stepDuration: config.parameters["stepDuration"] as? TimeInterval ?? 30.0
            )
        }
        }
    }
}

// MARK: - Supporting Types

/// Configuration for running scenarios.
public struct ScenarioConfiguration: Codable, Sendable {
    public let scenarios: [ScenarioConfig]
    public let executionMode: ExecutionMode
    public let safetyLimits: SafetyLimits?
    
    public enum ExecutionMode: Codable, Sendable {
        case sequential
        case single(Int)
    }
    
    public struct SafetyLimits: Codable, Sendable {
        public let maxCPU: Double?
        public let maxMemory: Double?
        public let maxFileDescriptors: Int?
    }
}

/// Configuration for a single scenario.
public struct ScenarioConfig: Codable, Sendable {
    public let type: ScenarioType
    public let name: String?
    public let parameters: [String: Any]
    
    public enum ScenarioType: String, Codable, Sendable {
        case burst
        case sustained
        case chaos
        case rampUp
    }
    
    // Custom Codable implementation to handle [String: Any]
    enum CodingKeys: String, CodingKey {
        case type, name, parameters
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(ScenarioType.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        
        // Decode parameters as dictionary
        if let paramData = try? container.decode(Data.self, forKey: .parameters),
           let params = try? JSONSerialization.jsonObject(with: paramData) as? [String: Any] {
            parameters = params
        } else {
            parameters = [:]
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(name, forKey: .name)
        
        // Encode parameters
        if !parameters.isEmpty,
           let paramData = try? JSONSerialization.data(withJSONObject: parameters) {
            try container.encode(paramData, forKey: .parameters)
        }
    }
}

/// Status of scenario execution.
public struct ScenarioStatus: Sendable {
    public let isRunning: Bool
    public let currentScenario: String?
    public let orchestratorStatus: OrchestratorStatus
    public let safetyStatus: SafetyStatus
}

/// Errors related to scenario execution.
public enum ScenarioError: LocalizedError {
    case alreadyRunning
    case invalidConfiguration(String)
    case executionFailed(String)
    case safetyViolation(String)
    
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A scenario is already running"
        case .invalidConfiguration(let reason):
            return "Invalid scenario configuration: \(reason)"
        case .executionFailed(let reason):
            return "Scenario execution failed: \(reason)"
        case .safetyViolation(let reason):
            return "Safety violation detected: \(reason)"
        }
    }
}