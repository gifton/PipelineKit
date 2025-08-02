import Foundation

/// Central coordinator for stress test execution.
///
/// The StressOrchestrator manages the lifecycle of stress tests, coordinating
/// between scenarios, simulators, safety monitoring, and resource management.
/// It ensures safe execution while collecting comprehensive metrics.
public actor StressOrchestrator {
    /// Current orchestrator state.
    public enum State: Sendable, Equatable {
        case idle
        case preparing
        case executing(scenario: String)
        case cleaningUp
        case shutdown
    }
    
    /// The current state of the orchestrator.
    private(set) var state: State = .idle
    
    /// Safety monitor for system protection.
    public let safetyMonitor: any SafetyMonitor
    
    /// Resource manager for tracking allocations.
    public let resourceManager: ResourceManager
    
    /// Metrics collector for performance data.
    public let metricCollector: MetricCollector
    
    /// Stress simulators - lazy initialized
    private var _memorySimulator: MemoryPressureSimulator?
    private var _cpuSimulator: CPULoadSimulator?
    private var _concurrencyStressor: ConcurrencyStressor?
    
    /// Currently executing scenario task.
    private var executionTask: Task<Void, Error>?
    
    /// Event handlers for lifecycle events.
    private var eventHandlers: [EventHandler] = []
    
    public init(
        safetyMonitor: (any SafetyMonitor)? = nil,
        resourceManager: ResourceManager? = nil,
        metricCollector: MetricCollector? = nil
    ) {
        self.safetyMonitor = safetyMonitor ?? DefaultSafetyMonitor()
        self.resourceManager = resourceManager ?? ResourceManager()
        self.metricCollector = metricCollector ?? MetricCollector()
    }
    
    /// Executes a stress test scenario.
    ///
    /// - Parameters:
    ///   - scenario: The scenario to execute.
    ///   - configuration: Optional configuration overrides.
    /// - Returns: The test results including metrics and any issues.
    /// - Throws: Errors during setup, execution, or if safety limits are exceeded.
    public func execute(
        _ scenario: any StressScenario,
        configuration: ScenarioConfiguration? = nil
    ) async throws -> StressTestResult {
        guard state == .idle else {
            throw PipelineError.test(reason: "Invalid orchestrator state: expected idle, got \(state)")
        }
        
        state = .preparing
        await notifyEvent(.scenarioStarted(scenario.name))
        
        // Start metrics collection
        await metricCollector.start()
        
        // Capture baseline metrics
        let baselineMetrics = await captureMetrics(phase: .baseline)
        
        do {
            // Check resource requirements
            try await validateResourceRequirements(scenario.requiredResources)
            
            // Set up the scenario
            try await scenario.setUp()
            
            // Execute with timeout and safety monitoring
            state = .executing(scenario: scenario.name)
            
            executionTask = Task {
                try await scenario.execute(with: self)
            }
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Main execution
                group.addTask { [executionTask] in
                    try await executionTask!.value
                }
                
                // Timeout monitor
                group.addTask { [weak self] in
                    try await Task.sleep(nanoseconds: UInt64(scenario.timeout * 1_000_000_000))
                    await self?.handleTimeout(scenario: scenario.name)
                    throw PipelineError.test(reason: "Scenario '\(scenario.name)' timed out after \(scenario.timeout) seconds")
                }
                
                // Safety monitor
                group.addTask { [weak self] in
                    try await self?.monitorSafety()
                }
                
                // Wait for first completion (success or failure)
                try await group.next()
                group.cancelAll()
            }
            
            // Capture peak metrics
            let peakMetrics = await captureMetrics(phase: .peak)
            
            // Clean up
            state = .cleaningUp
            try await scenario.tearDown()
            
            // Capture recovery metrics
            let recoveryMetrics = await captureMetrics(phase: .recovery)
            
            // Stop metrics collection
            await metricCollector.stop()
            let collectedMetrics = DetailedMetrics(samples: [])
            
            state = .idle
            await notifyEvent(.scenarioCompleted(scenario.name))
            
            return StressTestResult(
                scenarioName: scenario.name,
                status: .passed,
                baselineMetrics: baselineMetrics,
                peakMetrics: peakMetrics,
                recoveryMetrics: recoveryMetrics,
                detailedMetrics: collectedMetrics,
                warnings: await safetyMonitor.checkSystemHealth(),
                errors: []
            )
            
        } catch {
            // Ensure cleanup happens even on failure
            state = .cleaningUp
            executionTask?.cancel()
            
            try? await scenario.tearDown()
            await resourceManager.releaseAll()
            
            await metricCollector.stop()
            let collectedMetrics = DetailedMetrics(samples: [])
            
            state = .idle
            await notifyEvent(.scenarioFailed(scenario.name, error))
            
            return StressTestResult(
                scenarioName: scenario.name,
                status: .failed,
                baselineMetrics: baselineMetrics,
                peakMetrics: await captureMetrics(phase: .peak),
                recoveryMetrics: await captureMetrics(phase: .recovery),
                detailedMetrics: collectedMetrics,
                warnings: await safetyMonitor.checkSystemHealth(),
                errors: [error]
            )
        }
    }
    
    /// Shuts down the orchestrator and releases all resources.
    public func shutdown() async {
        guard state != .shutdown else { return }
        
        state = .shutdown
        executionTask?.cancel()
        
        await safetyMonitor.emergencyShutdown()
        await resourceManager.releaseAll()
        await metricCollector.stop()
        
        await notifyEvent(.orchestratorShutdown)
    }
    
    // MARK: - Simulators
    
    /// Provides access to the memory pressure simulator.
    public var memorySimulator: MemoryPressureSimulator {
        get async {
            if let simulator = _memorySimulator {
                return simulator
            }
            
            let simulator = MemoryPressureSimulator(
                resourceManager: resourceManager,
                safetyMonitor: safetyMonitor
            )
            _memorySimulator = simulator
            return simulator
        }
    }
    
    /// Provides access to the CPU load simulator.
    public var cpuSimulator: CPULoadSimulator {
        get async {
            if let simulator = _cpuSimulator {
                return simulator
            }
            
            let simulator = CPULoadSimulator(
                safetyMonitor: safetyMonitor
            )
            _cpuSimulator = simulator
            return simulator
        }
    }
    
    /// Provides access to the concurrency stressor.
    public var concurrencyStressor: ConcurrencyStressor {
        get async {
            if let stressor = _concurrencyStressor {
                return stressor
            }
            
            let stressor = ConcurrencyStressor(
                safetyMonitor: safetyMonitor,
                metricCollector: nil  // TODO: Add proper metric collector
            )
            _concurrencyStressor = stressor
            return stressor
        }
    }
    
    // MARK: - Event Handling
    
    /// Registers an event handler.
    public func addEventHandler(_ handler: @escaping EventHandler) {
        eventHandlers.append(handler)
    }
    
    /// Removes all event handlers.
    public func clearEventHandlers() {
        eventHandlers.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func validateResourceRequirements(_ requirements: ResourceRequirements) async throws {
        if let memoryRequired = requirements.memory {
            guard await safetyMonitor.canAllocateMemory(memoryRequired) else {
                throw PipelineError.resource(reason: .unavailable(resource: "memory"))
            }
        }
        
        if let cpuRequired = requirements.cpuCores {
            let available = SystemInfo.cpuCoreCount()
            guard cpuRequired <= available else {
                throw PipelineError.resource(reason: .unavailable(resource: "cpu"))
            }
        }
    }
    
    private func captureMetrics(phase: MetricsPhase) async -> StressTestMetrics {
        StressTestMetrics(
            phase: phase,
            timestamp: Date(),
            memoryUsage: SystemInfo.currentMemoryUsage(),
            cpuUsage: await SystemInfo.currentCPUUsage(),
            threadCount: ProcessInfo.processInfo.activeProcessorCount, // Use processor count as proxy
            resourceUsage: await resourceManager.currentUsage()
        )
    }
    
    private func monitorSafety() async throws {
        while !Task.isCancelled {
            let warnings = await safetyMonitor.checkSystemHealth()
            
            for warning in warnings where warning.level == .critical {
                throw PipelineError.resource(reason: .limitExceeded(resource: "safety", limit: 0))
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    private func handleTimeout(scenario: String) async {
        await notifyEvent(.scenarioTimeout(scenario))
        executionTask?.cancel()
    }
    
    private func notifyEvent(_ event: OrchestratorEvent) async {
        for handler in eventHandlers {
            await handler(event)
        }
    }
    
    // MARK: - Simulation Management
    
    /// Active simulations tracking.
    private var activeSimulations: [UUID: SimulationInfo] = [:]
    
    private struct SimulationInfo {
        let type: SimulationType
        let task: Task<Void, Never>
        let startTime: Date
    }
    
    private enum SimulationType {
        case cpuLoad
        case memoryPressure
        case concurrency
        case resourceExhaustion
    }
    
    /// Schedules a CPU load scenario.
    public func schedule(_ scenario: CPULoadScenario) async throws -> UUID {
        let id = UUID()
        let simulator = await cpuSimulator
        
        let task = Task {
            do {
                switch scenario.pattern {
                case .constant(let percentage):
                    try await simulator.applySustainedLoad(
                        percentage: percentage,
                        cores: scenario.cores,
                        duration: scenario.duration
                    )
                    
                case .sine(let min, let max, let period):
                    try await simulator.applyOscillatingLoad(
                        minPercentage: min,
                        maxPercentage: max,
                        period: period,
                        cores: scenario.cores,
                        cycles: Int(scenario.duration / period)
                    )
                    
                case .burst(let peak, let duration, let interval):
                    try await simulator.applyBurstLoad(
                        percentage: peak,
                        cores: scenario.cores,
                        burstDuration: duration,
                        idleDuration: interval,
                        totalDuration: scenario.duration
                    )
                }
            } catch {
                await metricCollector.recordEvent("simulation.failed", tags: [
                    "type": "cpu",
                    "pattern": String(describing: scenario.pattern),
                    "error": error.localizedDescription
                ])
            }
        }
        
        activeSimulations[id] = SimulationInfo(
            type: .cpuLoad,
            task: task,
            startTime: Date()
        )
        
        await metricCollector.recordEvent("simulation.scheduled", tags: [
            "type": "cpu",
            "duration": String(scenario.duration),
            "cores": String(scenario.cores)
        ])
        
        return id
    }
    
    /// Schedules a basic memory scenario.
    public func schedule(_ scenario: BasicMemoryScenario) async throws -> UUID {
        let id = UUID()
        let simulator = await memorySimulator
        
        let task = Task {
            do {
                let targetBytes = Int(scenario.targetPercentage * Double(SystemInfo.totalMemory()))
                
                switch scenario.allocationPattern {
                case .immediate:
                    // Use burst allocation for immediate pattern
                    try await simulator.burst(
                        size: targetBytes,
                        holdTime: scenario.duration
                    )
                    
                case .gradual(_):
                    // Use gradual pressure for gradual pattern
                    try await simulator.applyGradualPressure(
                        targetUsage: scenario.targetPercentage,
                        duration: scenario.duration
                    )
                    
                case .burst(let count, let size):
                    // Multiple bursts with specified size
                    for _ in 0..<count {
                        try await simulator.burst(
                            size: size,
                            holdTime: scenario.duration / Double(count)
                        )
                    }
                }
                
                // Release will happen automatically when task completes
                await simulator.releaseAll()
            } catch {
                await metricCollector.recordEvent("simulation.failed", tags: [
                    "type": "memory",
                    "target_percentage": String(scenario.targetPercentage),
                    "error": error.localizedDescription
                ])
            }
        }
        
        activeSimulations[id] = SimulationInfo(
            type: .memoryPressure,
            task: task,
            startTime: Date()
        )
        
        await metricCollector.recordEvent("simulation.scheduled", tags: [
            "type": "memory",
            "duration": String(scenario.duration),
            "target_percentage": String(scenario.targetPercentage)
        ])
        
        return id
    }
    
    /// Schedules a concurrency pattern.
    public func schedulePattern(_ pattern: ConcurrencyPattern, duration: TimeInterval) async throws -> UUID {
        let id = UUID()
        let stressor = await concurrencyStressor
        
        let task = Task {
            do {
                switch pattern {
                case .taskExplosion(let taskCount, let taskDuration, let burstInterval):
                    // Calculate tasks per second from burst interval
                    let tasksPerSecond = Int(Double(taskCount) / burstInterval)
                    try await stressor.simulateTaskExplosion(
                        tasksPerSecond: tasksPerSecond,
                        duration: duration,
                        taskWork: Int(taskDuration * 1_000_000)  // Convert to microseconds
                    )
                    
                case .actorContention(let actorCount, let messagesPerActor, let messageInterval):
                    // Run actor contention for the specified duration
                    let endTime = Date().addingTimeInterval(duration)
                    while Date() < endTime {
                        try Task.checkCancellation()
                        try await stressor.createActorContention(
                            actorCount: actorCount,
                            messagesPerActor: messagesPerActor,
                            messageSize: 1024  // Using default message size
                        )
                        // Wait for the message interval before next batch
                        try await Task.sleep(nanoseconds: UInt64(messageInterval * 1_000_000_000))
                    }
                    
                case .lockContention(let threadCount, let lockCount, let holdDuration):
                    // Calculate contention factor from lock count and thread count
                    let contentionFactor = min(1.0, Double(lockCount) / Double(threadCount))
                    try await stressor.createLockContention(
                        threads: threadCount,
                        contentionFactor: contentionFactor,
                        duration: holdDuration
                    )
                }
            } catch {
                await metricCollector.recordEvent("simulation.failed", tags: [
                    "type": "concurrency",
                    "pattern": String(describing: pattern),
                    "error": error.localizedDescription
                ])
            }
        }
        
        activeSimulations[id] = SimulationInfo(
            type: .concurrency,
            task: task,
            startTime: Date()
        )
        
        await metricCollector.recordEvent("simulation.scheduled", tags: [
            "type": "concurrency",
            "duration": String(duration),
            "pattern": String(describing: pattern)
        ])
        
        return id
    }
    
    /// Schedules resource exhaustion.
    public func scheduleExhaustion(_ request: ExhaustionRequest) async throws -> UUID {
        let id = UUID()
        
        // We need to create a ResourceExhauster instance for this simulation
        let exhauster = ResourceExhauster(
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
        
        let task = Task {
            do {
                // ResourceExhauster.exhaust handles both percentage and absolute amounts internally
                _ = try await exhauster.exhaust(request)
            } catch {
                await metricCollector.recordEvent("simulation.failed", tags: [
                    "type": "resource_exhaustion",
                    "resource": String(describing: request.resource),
                    "error": error.localizedDescription
                ])
            }
        }
        
        activeSimulations[id] = SimulationInfo(
            type: .resourceExhaustion,
            task: task,
            startTime: Date()
        )
        
        await metricCollector.recordEvent("simulation.scheduled", tags: [
            "type": "resource_exhaustion",
            "duration": String(request.duration),
            "resource": String(describing: request.resource)
        ])
        
        return id
    }
    
    /// Stops a running simulation.
    public func stop(_ simulationId: UUID) async {
        guard let info = activeSimulations[simulationId] else { return }
        
        info.task.cancel()
        activeSimulations.removeValue(forKey: simulationId)
        
        await notifyEvent(.simulationStopped(simulationId))
    }
    
    /// Stops all running simulations.
    public func stopAll() async {
        for (_, info) in activeSimulations {
            info.task.cancel()
        }
        activeSimulations.removeAll()
        
        await notifyEvent(.allSimulationsStopped)
    }
    
    /// Updates simulation parameters (if supported).
    public func updateSimulation(_ simulationId: UUID, parameters: [String: Any]) async {
        guard let info = activeSimulations[simulationId] else {
            await metricCollector.recordEvent("simulation.update_failed", tags: [
                "simulation_id": simulationId.uuidString,
                "reason": "simulation_not_found"
            ])
            return
        }
        
        // Log update attempt
        await metricCollector.recordEvent("simulation.update_started", tags: [
            "simulation_id": simulationId.uuidString,
            "type": String(describing: info.type),
            "parameters": String(describing: parameters.keys)
        ])
        
        // Note: Dynamic parameter updates would require simulators to support
        // live configuration changes. This is architecturally complex as it
        // requires thread-safe parameter passing and simulators that can
        // adapt their behavior mid-execution.
        //
        // For now, we log the attempt. Future implementations could:
        // 1. Add a parameter update protocol for simulators
        // 2. Use async streams or channels for parameter updates
        // 3. Implement pause/modify/resume patterns
        
        await metricCollector.recordEvent("simulation.update_completed", tags: [
            "simulation_id": simulationId.uuidString,
            "status": "logged_only"
        ])
    }
    
    /// Gets the current status of all simulations.
    public func currentStatus() -> OrchestratorStatus {
        let simulations = activeSimulations.map { id, info in
            SimulationStatus(
                id: id,
                type: String(describing: info.type),
                duration: Date().timeIntervalSince(info.startTime)
            )
        }
        
        return OrchestratorStatus(
            state: String(describing: state),
            activeSimulations: simulations
        )
    }
}

// MARK: - Supporting Types

/// Events emitted by the orchestrator.
public enum OrchestratorEvent: Sendable {
    case scenarioStarted(String)
    case scenarioCompleted(String)
    case scenarioFailed(String, Error)
    case scenarioTimeout(String)
    case orchestratorShutdown
    case simulationStopped(UUID)
    case allSimulationsStopped
}

/// Event handler type.
public typealias EventHandler = @Sendable (OrchestratorEvent) async -> Void

/// Errors that can occur during orchestration.



/// Phases of metric collection.
public enum MetricsPhase: String, Sendable {
    case baseline
    case peak
    case recovery
}

/// Stress test metrics snapshot.
public struct StressTestMetrics: Sendable {
    public let phase: MetricsPhase
    public let timestamp: Date
    public let memoryUsage: Int
    public let cpuUsage: Double
    public let threadCount: Int
    public let resourceUsage: ResourceUsage
}

/// Detailed metrics from continuous collection.
public struct DetailedMetrics: Sendable {
    public let samples: [MetricSample]
}

/// A single metric sample.
public struct MetricSample: Sendable {
    public let timestamp: Date
    public let metrics: [String: Double]
}

/// Result of a stress test execution.
public struct StressTestResult: Sendable {
    public enum Status: Sendable {
        case passed
        case failed
        case timeout
    }
    
    public let scenarioName: String
    public let status: Status
    public let baselineMetrics: StressTestMetrics
    public let peakMetrics: StressTestMetrics
    public let recoveryMetrics: StressTestMetrics
    public let detailedMetrics: DetailedMetrics
    public let warnings: [SafetyWarning]
    public let errors: [Error]
}

/// Status of the orchestrator.
public struct OrchestratorStatus: Sendable {
    public let state: String
    public let activeSimulations: [SimulationStatus]
}

/// Status of a single simulation.
public struct SimulationStatus: Sendable {
    public let id: UUID
    public let type: String
    public let duration: TimeInterval
}

// MARK: - Simulation Types

/// CPU load scenario configuration.
public struct CPULoadScenario: Sendable {
    public let pattern: CPULoadPattern
    public let duration: TimeInterval
    public let cores: Int
    
    public init(
        pattern: CPULoadPattern,
        duration: TimeInterval,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.pattern = pattern
        self.duration = duration
        self.cores = cores
    }
}

/// CPU load patterns.
public enum CPULoadPattern: Sendable {
    case constant(percentage: Double)
    case sine(min: Double, max: Double, period: TimeInterval)
    case burst(peak: Double, duration: TimeInterval, interval: TimeInterval)
}

/// Concurrency pattern for stress testing.
public enum ConcurrencyPattern: Sendable {
    case taskExplosion(taskCount: Int, taskDuration: TimeInterval, burstInterval: TimeInterval)
    case actorContention(actorCount: Int, messagesPerActor: Int, messageInterval: TimeInterval)
    case lockContention(threadCount: Int, lockCount: Int, holdDuration: TimeInterval)
}