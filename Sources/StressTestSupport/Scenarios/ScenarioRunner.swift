import Foundation
import PipelineKitCore

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
            throw PipelineError.simulation(reason: .scenario(.alreadyRunning))
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
                throw PipelineError.simulation(reason: .scenario(.invalidConfiguration(reason: "Scenario index out of range")))
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
            switch config.parameters {
            case .burst(let idle, let spike, let recovery):
                return BurstLoadScenario(
                    name: config.name ?? "BurstLoad",
                    metricCollector: metricCollector,
                    idleDuration: idle,
                    spikeDuration: spike,
                    recoveryDuration: recovery
                )
                
            case .sustained(let duration):
                return SustainedLoadScenario(
                    name: config.name ?? "SustainedLoad",
                    metricCollector: metricCollector,
                    sustainedDuration: duration
                )
                
            case .chaos(let duration, let seed):
                return ChaosScenario(
                    name: config.name ?? "Chaos",
                    metricCollector: metricCollector,
                    totalDuration: duration,
                    seed: seed
                )
                
            case .rampUp(let start, let end, let step):
                return RampUpScenario(
                    name: config.name ?? "RampUp",
                    metricCollector: metricCollector,
                    startIntensity: start,
                    endIntensity: end,
                    stepDuration: step
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

/// Configuration for a single scenario with typed parameters.
public struct ScenarioConfig: Codable, Sendable {
    public let type: ScenarioType
    public let name: String?
    public let parameters: ScenarioParameters
    
    public enum ScenarioType: String, Codable, Sendable {
        case burst
        case sustained
        case chaos
        case rampUp
    }
    
    /// Typed parameters for different scenario types.
    public enum ScenarioParameters: Codable, Sendable {
        case burst(idleDuration: TimeInterval, spikeDuration: TimeInterval, recoveryDuration: TimeInterval)
        case sustained(duration: TimeInterval)
        case chaos(duration: TimeInterval, seed: UInt64?)
        case rampUp(startIntensity: Double, endIntensity: Double, stepDuration: TimeInterval)
    }
    
    // Custom Codable implementation for JSON serialization
    enum CodingKeys: String, CodingKey {
        case type, name, parameters
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(ScenarioType.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        
        // Try to decode typed parameters based on scenario type
        if let parametersData = try? container.decode(Data.self, forKey: .parameters),
           let paramsDict = try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any] {
            
            switch type {
            case .burst:
                let idle = (paramsDict["idleDuration"] as? TimeInterval) ?? 10.0
                let spike = (paramsDict["spikeDuration"] as? TimeInterval) ?? 40.0
                let recovery = (paramsDict["recoveryDuration"] as? TimeInterval) ?? 20.0
                parameters = .burst(idleDuration: idle, spikeDuration: spike, recoveryDuration: recovery)
                
            case .sustained:
                let duration = (paramsDict["duration"] as? TimeInterval) ?? 900.0
                parameters = .sustained(duration: duration)
                
            case .chaos:
                let duration = (paramsDict["duration"] as? TimeInterval) ?? 300.0
                let seed = paramsDict["seed"] as? UInt64
                parameters = .chaos(duration: duration, seed: seed)
                
            case .rampUp:
                let start = (paramsDict["startIntensity"] as? Double) ?? 0.1
                let end = (paramsDict["endIntensity"] as? Double) ?? 0.95
                let step = (paramsDict["stepDuration"] as? TimeInterval) ?? 30.0
                parameters = .rampUp(startIntensity: start, endIntensity: end, stepDuration: step)
            }
        } else {
            // Default parameters based on type
            switch type {
            case .burst:
                parameters = .burst(idleDuration: 10.0, spikeDuration: 40.0, recoveryDuration: 20.0)
            case .sustained:
                parameters = .sustained(duration: 900.0)
            case .chaos:
                parameters = .chaos(duration: 300.0, seed: nil)
            case .rampUp:
                parameters = .rampUp(startIntensity: 0.1, endIntensity: 0.95, stepDuration: 30.0)
            }
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(name, forKey: .name)
        
        // Encode parameters back to dictionary format for compatibility
        var paramsDict: [String: Any] = [:]
        
        switch parameters {
        case .burst(let idle, let spike, let recovery):
            paramsDict = ["idleDuration": idle, "spikeDuration": spike, "recoveryDuration": recovery]
        case .sustained(let duration):
            paramsDict = ["duration": duration]
        case .chaos(let duration, let seed):
            paramsDict = ["duration": duration]
            if let seed = seed {
                paramsDict["seed"] = seed
            }
        case .rampUp(let start, let end, let step):
            paramsDict = ["startIntensity": start, "endIntensity": end, "stepDuration": step]
        }
        
        if !paramsDict.isEmpty,
           let paramData = try? JSONSerialization.data(withJSONObject: paramsDict) {
            try container.encode(paramData, forKey: .parameters)
        }
    }
    
    // Convenience initializers for creating typed configs
    public init(type: ScenarioType, name: String? = nil, parameters: ScenarioParameters) {
        self.type = type
        self.name = name
        self.parameters = parameters
    }
}

/// Status of scenario execution.
public struct ScenarioStatus: Sendable {
    public let isRunning: Bool
    public let currentScenario: String?
    public let orchestratorStatus: OrchestratorStatus
    public let safetyStatus: SafetyStatus
}

// Scenario errors are now part of PipelineError.simulation(reason: .scenario(...))