import Foundation

/// Scenario that creates random, unpredictable load patterns.
///
/// This scenario randomly selects simulators, intensities, and durations
/// to create chaotic conditions that test system resilience.
@MainActor
public final class ChaosScenario: BaseScenario {
    // Chaos configuration
    public let totalDuration: TimeInterval
    public let seed: UInt64?
    public let minSimulationDuration: TimeInterval
    public let maxSimulationDuration: TimeInterval
    public let simulationGapRange: ClosedRange<TimeInterval>
    
    // Simulator configurations with weights and intensity ranges
    public let simulatorConfigs: [SimulatorConfig]
    
    public struct SimulatorConfig: Sendable {
        public enum SimulatorType: String, Sendable {
            case cpu
            case memory
            case concurrency
            case resources
        }
        
        public let type: SimulatorType
        public let weight: Double // Probability weight for selection
        public let intensityRange: IntensityRange
        public let resourceTypes: [ResourceExhauster.ResourceType]? // For resources simulator
        
        public init(
            type: SimulatorType,
            weight: Double = 1.0,
            intensityRange: IntensityRange = IntensityRange(min: 0.1, max: 0.9),
            resourceTypes: [ResourceExhauster.ResourceType]? = nil
        ) {
            self.type = type
            self.weight = weight
            self.intensityRange = intensityRange
            self.resourceTypes = resourceTypes
        }
        
        public static let defaultConfigs: [SimulatorConfig] = [
            SimulatorConfig(type: .cpu, weight: 1.5, intensityRange: IntensityRange(min: 0.2, max: 0.95)),
            SimulatorConfig(type: .memory, weight: 1.2, intensityRange: IntensityRange(min: 0.1, max: 0.85)),
            SimulatorConfig(type: .concurrency, weight: 1.0, intensityRange: IntensityRange(min: 0.1, max: 0.8)),
            SimulatorConfig(type: .resources, weight: 0.8, intensityRange: IntensityRange(min: 0.1, max: 0.7),
                           resourceTypes: [.fileDescriptors, .networkSockets, .memoryMappings])
        ]
    }
    
    private var rng: any RandomNumberGenerator
    
    public init(
        name: String = "Chaos",
        metricCollector: MetricCollector? = nil,
        totalDuration: TimeInterval = 300.0, // 5 minutes default
        seed: UInt64? = nil,
        minSimulationDuration: TimeInterval = 5.0,
        maxSimulationDuration: TimeInterval = 45.0,
        simulationGapRange: ClosedRange<TimeInterval> = 1.0...3.0,
        simulatorConfigs: [SimulatorConfig] = SimulatorConfig.defaultConfigs
    ) {
        self.totalDuration = totalDuration
        self.seed = seed
        self.minSimulationDuration = minSimulationDuration
        self.maxSimulationDuration = maxSimulationDuration
        self.simulationGapRange = simulationGapRange
        self.simulatorConfigs = simulatorConfigs
        
        // Initialize RNG with seed for reproducibility
        if let seed = seed {
            self.rng = SeededRandomNumberGenerator(seed: seed)
        } else {
            self.rng = SystemRandomNumberGenerator()
        }
        
        super.init(name: name, metricCollector: metricCollector)
    }
    
    override public func runTimeline(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(totalDuration)
        var activeSimulations: Set<UUID> = []
        var chaosEventCount = 0
        
        // Record chaos parameters
        await recordChaosParameters()
        
        while Date() < endTime {
            // Check if we should stop due to safety
            let safetyStatus = await safetyMonitor.currentStatus()
            if safetyStatus.criticalViolations > 0 {
                await recordEvent("chaos.safety_abort", tags: [
                    "scenario": name,
                    "events_created": String(chaosEventCount),
                    "active_simulations": String(activeSimulations.count)
                ])
                break
            }
            
            // Randomly decide whether to start a new simulation or stop an existing one
            let shouldStart = Double.random(in: 0...1, using: &rng) > 0.3 || activeSimulations.isEmpty
            
            if shouldStart {
                // Start a new random simulation
                do {
                    let (simulationId, config) = try await startRandomSimulation(orchestrator: orchestrator)
                    activeSimulations.insert(simulationId)
                    chaosEventCount += 1
                    await recordChaosEvent(eventNumber: chaosEventCount, config: config, action: "start")
                } catch {
                    await recordEvent("chaos.simulation_failed", tags: [
                        "scenario": name,
                        "error": error.localizedDescription
                    ])
                }
            } else if let simulationToStop = activeSimulations.randomElement(using: &rng) {
                // Stop a random active simulation
                await orchestrator.stop(simulationToStop)
                activeSimulations.remove(simulationToStop)
                await recordChaosEvent(eventNumber: chaosEventCount, config: nil, action: "stop")
            }
            
            // Random gap before next action
            let gap = TimeInterval.random(in: simulationGapRange, using: &rng)
            try await sleepWithSafetyCheck(gap, safetyMonitor: safetyMonitor)
        }
        
        // Clean up any remaining simulations
        for simulationId in activeSimulations {
            await orchestrator.stop(simulationId)
        }
        
        await recordEvent("chaos.completed", tags: [
            "scenario": name,
            "total_events": String(chaosEventCount),
            "duration": String(Date().timeIntervalSince(startTime))
        ])
    }
    
    private func startRandomSimulation(
        orchestrator: StressOrchestrator
    ) async throws -> (UUID, SimulatorConfig) {
        // Select simulator based on weights
        let config = selectWeightedSimulator()
        let intensity = config.intensityRange.random(using: &rng)
        let duration = TimeInterval.random(
            in: minSimulationDuration...maxSimulationDuration,
            using: &rng
        )
        
        let simulationId: UUID
        
        switch config.type {
        case .cpu:
            let pattern = Bool.random(using: &rng) ?
                CPULoadPattern.constant(percentage: intensity) :
                CPULoadPattern.sine(
                    min: intensity * 0.5,
                    max: intensity,
                    period: duration / 3
                )
            let scenario = CPULoadScenario(pattern: pattern, duration: duration)
            simulationId = try await orchestrator.schedule(scenario)
            
        case .memory:
            let scenario = BasicMemoryScenario(
                targetPercentage: intensity,
                duration: duration,
                allocationPattern: Bool.random(using: &rng) ? .immediate : .gradual(steps: 5)
            )
            simulationId = try await orchestrator.schedule(scenario)
            
        case .concurrency:
            let threadCount = Int(intensity * 300) // Scale to thread count
            let pattern = [
                ConcurrencyPattern.taskExplosion(
                    taskCount: threadCount,
                    taskDuration: 0.5,
                    burstInterval: 2.0
                ),
                ConcurrencyPattern.actorContention(
                    actorCount: threadCount / 10,
                    messagesPerActor: 100,
                    messageInterval: 0.01
                ),
                ConcurrencyPattern.lockContention(
                    threadCount: threadCount / 2,
                    lockCount: 5,
                    holdDuration: 0.01
                )
            ].randomElement(using: &rng)!
            
            simulationId = try await orchestrator.schedulePattern(pattern, duration: duration)
            
        case .resources:
            let resourceType = (config.resourceTypes ?? [.fileDescriptors]).randomElement(using: &rng)!
            let request = ExhaustionRequest(
                resource: resourceType,
                amount: .percentage(intensity),
                duration: duration
            )
            simulationId = try await orchestrator.scheduleExhaustion(request)
        }
        
        return (simulationId, config)
    }
    
    private func selectWeightedSimulator() -> SimulatorConfig {
        let totalWeight = simulatorConfigs.reduce(0) { $0 + $1.weight }
        var randomValue = Double.random(in: 0..<totalWeight, using: &rng)
        
        for config in simulatorConfigs {
            randomValue -= config.weight
            if randomValue < 0 {
                return config
            }
        }
        
        return simulatorConfigs.last!
    }
    
    // MARK: - Metrics
    
    private func recordChaosParameters() async {
        await recordEvent("chaos.parameters", tags: [
            "scenario": name,
            "duration": String(totalDuration),
            "seed": seed.map(String.init) ?? "random",
            "min_duration": String(minSimulationDuration),
            "max_duration": String(maxSimulationDuration)
        ])
    }
    
    private func recordChaosEvent(
        eventNumber: Int,
        config: SimulatorConfig?,
        action: String
    ) async {
        var tags = [
            "scenario": name,
            "event": String(eventNumber),
            "action": action
        ]
        
        if let config = config {
            tags["simulator"] = config.type.rawValue
        }
        
        await recordEvent("chaos.event", tags: tags)
    }
}

/// Seeded random number generator for reproducible chaos.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        // Simple linear congruential generator
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
