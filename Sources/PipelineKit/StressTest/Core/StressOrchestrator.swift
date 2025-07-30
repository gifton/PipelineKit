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
    public let metricsCollector: StressMetricsCollector
    
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
        metricsCollector: StressMetricsCollector? = nil
    ) {
        self.safetyMonitor = safetyMonitor ?? DefaultSafetyMonitor()
        self.resourceManager = resourceManager ?? ResourceManager()
        self.metricsCollector = metricsCollector ?? StressMetricsCollector()
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
            throw OrchestratorError.invalidState(current: state, expected: .idle)
        }
        
        state = .preparing
        await notifyEvent(.scenarioStarted(scenario.name))
        
        // Start metrics collection
        await metricsCollector.startCollection()
        
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
                    throw OrchestratorError.timeout(scenario: scenario.name, limit: scenario.timeout)
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
            let collectedMetrics = await metricsCollector.stopCollection()
            
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
            
            let collectedMetrics = await metricsCollector.stopCollection()
            
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
        _ = await metricsCollector.stopCollection()
        
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
                throw OrchestratorError.insufficientResources(
                    type: .memory,
                    required: memoryRequired
                )
            }
        }
        
        if let cpuRequired = requirements.cpuCores {
            let available = SystemInfo.cpuCoreCount()
            guard cpuRequired <= available else {
                throw OrchestratorError.insufficientResources(
                    type: .cpu,
                    required: cpuRequired
                )
            }
        }
    }
    
    private func captureMetrics(phase: MetricsPhase) async -> StressTestMetrics {
        StressTestMetrics(
            phase: phase,
            timestamp: Date(),
            memoryUsage: SystemInfo.currentMemoryUsage(),
            cpuUsage: 0.0, // TODO: Implement CPU usage monitoring
            threadCount: ProcessInfo.processInfo.activeProcessorCount, // Use processor count as proxy
            resourceUsage: await resourceManager.currentUsage()
        )
    }
    
    private func monitorSafety() async throws {
        while !Task.isCancelled {
            let warnings = await safetyMonitor.checkSystemHealth()
            
            for warning in warnings where warning.level == .critical {
                throw OrchestratorError.safetyLimitExceeded(warning.message)
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
}

// MARK: - Supporting Types

/// Events emitted by the orchestrator.
public enum OrchestratorEvent: Sendable {
    case scenarioStarted(String)
    case scenarioCompleted(String)
    case scenarioFailed(String, Error)
    case scenarioTimeout(String)
    case orchestratorShutdown
}

/// Event handler type.
public typealias EventHandler = @Sendable (OrchestratorEvent) async -> Void

/// Errors that can occur during orchestration.
public enum OrchestratorError: LocalizedError {
    case invalidState(current: StressOrchestrator.State, expected: StressOrchestrator.State)
    case insufficientResources(type: ResourceType, required: Int)
    case timeout(scenario: String, limit: TimeInterval)
    case safetyLimitExceeded(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidState(let current, let expected):
            return "Invalid orchestrator state: \(current), expected \(expected)"
        case .insufficientResources(let type, let required):
            return "Insufficient resources: \(type) requires \(required)"
        case .timeout(let scenario, let limit):
            return "Scenario '\(scenario)' timed out after \(limit)s"
        case .safetyLimitExceeded(let message):
            return "Safety limit exceeded: \(message)"
        }
    }
}


/// Metrics collector for stress testing
public actor StressMetricsCollector {
    public init() {}
    
    public func startCollection() async {}
    
    public func stopCollection() async -> DetailedMetrics {
        DetailedMetrics(samples: [])
    }
}

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