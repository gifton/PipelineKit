import Foundation

/// Scenario that gradually increases load over time.
///
/// This scenario starts with low load and incrementally increases it,
/// useful for finding system breaking points and performance cliffs.
@MainActor
public final class RampUpScenario: BaseScenario {
    
    // Ramp configuration
    public let startIntensity: Double
    public let endIntensity: Double
    public let stepSize: Double
    public let stepDuration: TimeInterval
    public let holdAtPeakDuration: TimeInterval
    public let rampDownDuration: TimeInterval
    
    // Ramp style
    public enum RampStyle: String, Sendable {
        case linear = "linear"
        case exponential = "exponential"
        case logarithmic = "logarithmic"
    }
    public let rampStyle: RampStyle
    
    // Active simulations tracking
    private var activeSimulations: [SimulatorType: UUID] = [:]
    
    private enum SimulatorType: String, CaseIterable {
        case cpu = "cpu"
        case memory = "memory"
        case concurrency = "concurrency"
        case resources = "resources"
    }
    
    public init(
        name: String = "RampUp",
        metricCollector: MetricCollector? = nil,
        startIntensity: Double = 0.1,
        endIntensity: Double = 0.95,
        stepSize: Double = 0.05,
        stepDuration: TimeInterval = 30.0,
        holdAtPeakDuration: TimeInterval = 120.0,
        rampDownDuration: TimeInterval = 60.0,
        rampStyle: RampStyle = .linear
    ) {
        self.startIntensity = startIntensity
        self.endIntensity = endIntensity
        self.stepSize = stepSize
        self.stepDuration = stepDuration
        self.holdAtPeakDuration = holdAtPeakDuration
        self.rampDownDuration = rampDownDuration
        self.rampStyle = rampStyle
        
        super.init(name: name, metricCollector: metricCollector)
    }
    
    override public func runTimeline(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        // Calculate ramp steps
        let steps = calculateRampSteps()
        
        await recordEvent("ramp.start", tags: [
            "scenario": name,
            "start_intensity": String(format: "%.2f", startIntensity),
            "end_intensity": String(format: "%.2f", endIntensity),
            "steps": String(steps.count),
            "style": rampStyle.rawValue
        ])
        
        // Initial setup with minimal load
        try await setupInitialSimulators(orchestrator: orchestrator, intensity: startIntensity)
        
        // Ramp up phase
        for (index, intensity) in steps.enumerated() {
            // Check safety before increasing
            let safetyStatus = await safetyMonitor.currentStatus()
            if safetyStatus.criticalViolations > 0 {
                await recordEvent("ramp.safety_abort", tags: [
                    "scenario": name,
                    "step": String(index),
                    "intensity": String(format: "%.2f", intensity),
                    "violations": String(safetyStatus.criticalViolations)
                ])
                break
            }
            
            // Update all simulators to new intensity
            try await updateIntensity(orchestrator: orchestrator, to: intensity)
            
            await recordEvent("ramp.step", tags: [
                "scenario": name,
                "step": String(index + 1),
                "total_steps": String(steps.count),
                "intensity": String(format: "%.2f", intensity)
            ])
            
            // Hold at this level
            try await sleepWithSafetyCheck(stepDuration, safetyMonitor: safetyMonitor)
            
            // Record metrics at this level
            await recordIntensityMetrics(intensity: intensity, step: index + 1)
        }
        
        // Hold at peak
        await recordEvent("ramp.peak_hold", tags: [
            "scenario": name,
            "intensity": String(format: "%.2f", endIntensity),
            "duration": String(holdAtPeakDuration)
        ])
        try await sleepWithSafetyCheck(holdAtPeakDuration, safetyMonitor: safetyMonitor)
        
        // Ramp down phase
        await recordEvent("ramp.down_start", tags: [
            "scenario": name,
            "duration": String(rampDownDuration)
        ])
        
        // Gradually reduce to zero
        let rampDownSteps = 10
        let rampDownStepDuration = rampDownDuration / Double(rampDownSteps)
        
        for i in 0..<rampDownSteps {
            let intensity = endIntensity * (1.0 - Double(i + 1) / Double(rampDownSteps))
            try await updateIntensity(orchestrator: orchestrator, to: intensity)
            try await sleepWithSafetyCheck(rampDownStepDuration, safetyMonitor: safetyMonitor)
        }
        
        // Clean up all simulations
        for (_, simulationId) in activeSimulations {
            await orchestrator.stop(simulationId)
        }
        activeSimulations.removeAll()
        
        await recordEvent("ramp.completed", tags: ["scenario": name])
    }
    
    private func calculateRampSteps() -> [Double] {
        var steps: [Double] = []
        let totalSteps = Int((endIntensity - startIntensity) / stepSize) + 1
        
        for i in 0..<totalSteps {
            let progress = Double(i) / Double(totalSteps - 1)
            let intensity: Double
            
            switch rampStyle {
            case .linear:
                intensity = startIntensity + (endIntensity - startIntensity) * progress
                
            case .exponential:
                // Exponential growth: slow start, rapid end
                let expProgress = (exp(progress * 2) - 1) / (exp(2) - 1)
                intensity = startIntensity + (endIntensity - startIntensity) * expProgress
                
            case .logarithmic:
                // Logarithmic growth: rapid start, slow end
                let logProgress = log(1 + progress * 9) / log(10)
                intensity = startIntensity + (endIntensity - startIntensity) * logProgress
            }
            
            steps.append(min(max(intensity, startIntensity), endIntensity))
        }
        
        return steps
    }
    
    private func setupInitialSimulators(
        orchestrator: StressOrchestrator,
        intensity: Double
    ) async throws {
        // CPU - Start with constant load
        let cpuScenario = CPULoadScenario(
            pattern: .constant(percentage: intensity),
            duration: 3600.0 // Long duration, we'll update it
        )
        activeSimulations[.cpu] = try await orchestrator.schedule(cpuScenario)
        
        // Memory - Gradual allocation
        let memoryScenario = BasicMemoryScenario(
            targetPercentage: intensity,
            duration: 3600.0,
            allocationPattern: .gradual(steps: 5)
        )
        activeSimulations[.memory] = try await orchestrator.schedule(memoryScenario)
        
        // Concurrency - Scale thread count with intensity
        let threadCount = Int(intensity * 200)
        let concurrencyPattern = ConcurrencyPattern.actorContention(
            actorCount: max(1, threadCount / 10),
            messagesPerActor: 50,
            messageInterval: 0.1
        )
        activeSimulations[.concurrency] = try await orchestrator.schedulePattern(
            concurrencyPattern,
            duration: 3600.0
        )
        
        // Resources - File descriptors
        let exhaustionRequest = ExhaustionRequest(
            resource: .fileDescriptors,
            amount: .percentage(intensity),
            duration: 3600.0
        )
        activeSimulations[.resources] = try await orchestrator.scheduleExhaustion(exhaustionRequest)
    }
    
    private func updateIntensity(
        orchestrator: StressOrchestrator,
        to intensity: Double
    ) async throws {
        // Update each simulator with new intensity
        // Note: This assumes orchestrator supports updateIntensity method
        // If not available, we'd need to stop and restart with new parameters
        
        for (simulatorType, simulationId) in activeSimulations {
            switch simulatorType {
            case .cpu:
                await orchestrator.updateSimulation(
                    simulationId,
                    parameters: ["intensity": intensity]
                )
            case .memory:
                await orchestrator.updateSimulation(
                    simulationId,
                    parameters: ["intensity": intensity]
                )
            case .concurrency:
                let threadCount = Int(intensity * 200)
                await orchestrator.updateSimulation(
                    simulationId,
                    parameters: ["threadCount": threadCount]
                )
            case .resources:
                await orchestrator.updateSimulation(
                    simulationId,
                    parameters: ["intensity": intensity]
                )
            }
        }
    }
    
    // MARK: - Metrics
    
    private func recordIntensityMetrics(intensity: Double, step: Int) async {
        await recordGauge("ramp.intensity", value: intensity, tags: [
            "scenario": name,
            "step": String(step)
        ])
        
        // Record per-simulator intensities
        for simulatorType in SimulatorType.allCases {
            await recordGauge("ramp.simulator.intensity", value: intensity, tags: [
                "scenario": name,
                "simulator": simulatorType.rawValue,
                "step": String(step)
            ])
        }
    }
}