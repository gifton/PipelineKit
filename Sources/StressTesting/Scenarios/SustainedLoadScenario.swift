import Foundation

/// Scenario that maintains constant load for an extended period.
///
/// This scenario simulates production steady-state conditions with
/// moderate, consistent pressure across all resource types.
@MainActor
public final class SustainedLoadScenario: BaseScenario {
    // Duration configuration
    public let sustainedDuration: TimeInterval
    
    // Load configuration
    public let loadIntensity: LoadIntensity
    
    public struct LoadIntensity: Sendable {
        public let cpu: Double
        public let memory: Double
        public let concurrency: Int
        public let resources: Double
        
        public init(
            cpu: Double = 0.7,
            memory: Double = 0.6,
            concurrency: Int = 150,
            resources: Double = 0.5
        ) {
            self.cpu = cpu
            self.memory = memory
            self.concurrency = concurrency
            self.resources = resources
        }
        
        public static let moderate = LoadIntensity()
        public static let light = LoadIntensity(
            cpu: 0.3,
            memory: 0.25,
            concurrency: 50,
            resources: 0.2
        )
        public static let heavy = LoadIntensity(
            cpu: 0.85,
            memory: 0.8,
            concurrency: 250,
            resources: 0.75
        )
    }
    
    public init(
        name: String = "SustainedLoad",
        metricCollector: MetricCollector? = nil,
        sustainedDuration: TimeInterval = 900.0, // 15 minutes default
        loadIntensity: LoadIntensity = .moderate
    ) {
        self.sustainedDuration = sustainedDuration
        self.loadIntensity = loadIntensity
        
        super.init(name: name, metricCollector: metricCollector)
    }
    
    override public func runTimeline(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        // Record start of sustained phase
        await recordPhaseTransition("sustained")
        
        // Schedule all simulators with the same duration
        let simulationIds = try await scheduleSimulators(
            orchestrator: orchestrator,
            duration: sustainedDuration
        )
        
        // Monitor progress with periodic checkpoints
        let checkpointInterval: TimeInterval = min(60.0, sustainedDuration / 10)
        let checkpoints = Int(sustainedDuration / checkpointInterval)
        
        for checkpoint in 1...checkpoints {
            try await sleepWithSafetyCheck(checkpointInterval, safetyMonitor: safetyMonitor)
            
            // Record checkpoint metrics
            await recordCheckpoint(checkpoint, of: checkpoints)
            
            // Check safety status (additional check after sleep)
            let safetyStatus = await safetyMonitor.currentStatus()
            if !safetyStatus.isHealthy {
                await recordSafetyEvent(safetyStatus)
            }
        }
        
        // Clean up all simulations
        for simulationId in simulationIds {
            await orchestrator.stop(simulationId)
        }
        
        await recordPhaseTransition("completed")
    }
    
    private func scheduleSimulators(
        orchestrator: StressOrchestrator,
        duration: TimeInterval
    ) async throws -> [UUID] {
        var simulationIds: [UUID] = []
        
        // CPU Load - Constant pattern
        let cpuScenario = CPULoadScenario(
            pattern: .constant(percentage: loadIntensity.cpu),
            duration: duration,
            cores: ProcessInfo.processInfo.activeProcessorCount
        )
        let cpuId = try await orchestrator.schedule(cpuScenario)
        simulationIds.append(cpuId)
        await recordSimulatorScheduled("cpu", intensity: loadIntensity.cpu)
        
        // Memory Pressure - Sustained allocation
        let memoryScenario = BasicMemoryScenario(
            targetPercentage: loadIntensity.memory,
            duration: duration,
            allocationPattern: .gradual(steps: 10)
        )
        let memoryId = try await orchestrator.schedule(memoryScenario)
        simulationIds.append(memoryId)
        await recordSimulatorScheduled("memory", intensity: loadIntensity.memory)
        
        // Concurrency Stress - Actor mailbox flooding for sustained period
        let concurrencyPattern = ConcurrencyPattern.actorContention(
            actorCount: 20,
            messagesPerActor: loadIntensity.concurrency,
            messageInterval: 0.1
        )
        let concurrencyId = try await orchestrator.schedulePattern(
            concurrencyPattern,
            duration: duration
        )
        simulationIds.append(concurrencyId)
        await recordSimulatorScheduled("concurrency", intensity: Double(loadIntensity.concurrency))
        
        // Resource Exhaustion - Mix of different resource types
        let resourceTypes: [ResourceExhauster.ResourceType] = [
            .fileDescriptors,
            .memoryMappings,
            .networkSockets
        ]
        
        for resourceType in resourceTypes {
            let exhaustionRequest = ExhaustionRequest(
                resource: resourceType,
                amount: .percentage(loadIntensity.resources),
                duration: duration
            )
            let resourceId = try await orchestrator.scheduleExhaustion(exhaustionRequest)
            simulationIds.append(resourceId)
            await recordSimulatorScheduled("resources.\(resourceType.rawValue)", intensity: loadIntensity.resources)
        }
        
        return simulationIds
    }
    
    // MARK: - Metrics
    
    private func recordPhaseTransition(_ phase: String) async {
        await recordEvent("phase.transition", tags: [
            "scenario": name,
            "phase": phase,
            "duration": String(sustainedDuration)
        ])
    }
    
    private func recordSimulatorScheduled(_ simulator: String, intensity: Double) async {
        await recordEvent("simulator.scheduled", tags: [
            "scenario": name,
            "simulator": simulator,
            "intensity": String(format: "%.2f", intensity),
            "duration": String(sustainedDuration)
        ])
    }
    
    private func recordCheckpoint(_ current: Int, of total: Int) async {
        let progress = Double(current) / Double(total)
        await recordGauge("scenario.progress", value: progress, tags: [
            "scenario": name,
            "checkpoint": String(current),
            "total": String(total)
        ])
    }
    
    private func recordSafetyEvent(_ status: SafetyStatus) async {
        await recordEvent("safety.status", tags: [
            "scenario": name,
            "healthy": String(status.isHealthy),
            "violations": String(status.warnings.count),
            "critical": String(status.criticalViolations)
        ])
    }
}
