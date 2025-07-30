import Foundation

/// Scenario that simulates a sudden spike in load followed by recovery.
///
/// Timeline:
/// 1. Idle period (baseline capture)
/// 2. Spike period (high load across all simulators)
/// 3. Recovery period (return to low load)
@MainActor
public final class BurstLoadScenario: BaseScenario {
    
    // Timing configuration
    public let idleDuration: TimeInterval
    public let spikeDuration: TimeInterval
    public let recoveryDuration: TimeInterval
    
    // Load configuration
    public let spikeIntensity: LoadIntensity
    public let recoveryIntensity: LoadIntensity
    
    public struct LoadIntensity: Sendable {
        public let cpu: Double
        public let memory: Double
        public let concurrency: Int
        public let resources: Double
        
        public init(
            cpu: Double = 0.9,
            memory: Double = 0.8,
            concurrency: Int = 200,
            resources: Double = 0.8
        ) {
            self.cpu = cpu
            self.memory = memory
            self.concurrency = concurrency
            self.resources = resources
        }
        
        public static let spike = LoadIntensity()
        public static let recovery = LoadIntensity(
            cpu: 0.1,
            memory: 0.1,
            concurrency: 10,
            resources: 0.1
        )
    }
    
    public init(
        name: String = "BurstLoad",
        metricCollector: MetricCollector? = nil,
        idleDuration: TimeInterval = 10.0,
        spikeDuration: TimeInterval = 40.0,
        recoveryDuration: TimeInterval = 20.0,
        spikeIntensity: LoadIntensity = .spike,
        recoveryIntensity: LoadIntensity = .recovery
    ) {
        self.idleDuration = idleDuration
        self.spikeDuration = spikeDuration
        self.recoveryDuration = recoveryDuration
        self.spikeIntensity = spikeIntensity
        self.recoveryIntensity = recoveryIntensity
        
        super.init(name: name, metricCollector: metricCollector)
    }
    
    override public func runTimeline(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        // Phase 1: Idle (baseline)
        await recordPhaseTransition("idle")
        try await sleepWithSafetyCheck(idleDuration, safetyMonitor: safetyMonitor)
        
        // Phase 2: Spike
        await recordPhaseTransition("spike")
        let spikeSimulations = try await scheduleSpike(
            orchestrator: orchestrator,
            duration: spikeDuration
        )
        
        // Wait for spike duration
        try await sleepWithSafetyCheck(spikeDuration, safetyMonitor: safetyMonitor)
        
        // Stop spike simulations
        for simulation in spikeSimulations {
            await orchestrator.stop(simulation)
        }
        
        // Phase 3: Recovery
        await recordPhaseTransition("recovery")
        let recoverySimulations = try await scheduleRecovery(
            orchestrator: orchestrator,
            duration: recoveryDuration
        )
        
        // Wait for recovery duration
        try await sleepWithSafetyCheck(recoveryDuration, safetyMonitor: safetyMonitor)
        
        // Stop recovery simulations
        for simulation in recoverySimulations {
            await orchestrator.stop(simulation)
        }
    }
    
    private func scheduleSpike(
        orchestrator: StressOrchestrator,
        duration: TimeInterval
    ) async throws -> [UUID] {
        var simulationIds: [UUID] = []
        
        // CPU Load
        let cpuScenario = CPULoadScenario(
            pattern: .constant(percentage: spikeIntensity.cpu),
            duration: duration
        )
        let cpuId = try await orchestrator.schedule(cpuScenario)
        simulationIds.append(cpuId)
        await recordSimulatorScheduled("cpu", intensity: spikeIntensity.cpu)
        
        // Memory Pressure
        let memoryScenario = BasicMemoryScenario(
            targetPercentage: spikeIntensity.memory,
            duration: duration
        )
        let memoryId = try await orchestrator.schedule(memoryScenario)
        simulationIds.append(memoryId)
        await recordSimulatorScheduled("memory", intensity: spikeIntensity.memory)
        
        // Concurrency Stress
        let concurrencyPattern = ConcurrencyPattern.taskExplosion(
            taskCount: spikeIntensity.concurrency,
            taskDuration: 0.1,
            burstInterval: 1.0
        )
        let concurrencyId = try await orchestrator.schedulePattern(
            concurrencyPattern,
            duration: duration
        )
        simulationIds.append(concurrencyId)
        await recordSimulatorScheduled("concurrency", intensity: Double(spikeIntensity.concurrency))
        
        // Resource Exhaustion
        let exhaustionRequest = ExhaustionRequest(
            resource: .fileDescriptors,
            amount: .percentage(spikeIntensity.resources),
            duration: duration
        )
        let resourceId = try await orchestrator.scheduleExhaustion(exhaustionRequest)
        simulationIds.append(resourceId)
        await recordSimulatorScheduled("resources", intensity: spikeIntensity.resources)
        
        return simulationIds
    }
    
    private func scheduleRecovery(
        orchestrator: StressOrchestrator,
        duration: TimeInterval
    ) async throws -> [UUID] {
        var simulationIds: [UUID] = []
        
        // Low CPU Load
        let cpuScenario = CPULoadScenario(
            pattern: .constant(percentage: recoveryIntensity.cpu),
            duration: duration
        )
        let cpuId = try await orchestrator.schedule(cpuScenario)
        simulationIds.append(cpuId)
        await recordSimulatorScheduled("cpu", intensity: recoveryIntensity.cpu)
        
        // Low Memory
        let memoryScenario = BasicMemoryScenario(
            targetPercentage: recoveryIntensity.memory,
            duration: duration
        )
        let memoryId = try await orchestrator.schedule(memoryScenario)
        simulationIds.append(memoryId)
        await recordSimulatorScheduled("memory", intensity: recoveryIntensity.memory)
        
        return simulationIds
    }
    
    // MARK: - Metrics
    
    private func recordPhaseTransition(_ phase: String) async {
        await recordEvent("phase.transition", tags: [
            "scenario": name,
            "phase": phase
        ])
    }
    
    private func recordSimulatorScheduled(_ simulator: String, intensity: Double) async {
        await recordEvent("simulator.scheduled", tags: [
            "scenario": name,
            "simulator": simulator,
            "intensity": String(format: "%.2f", intensity)
        ])
    }
}