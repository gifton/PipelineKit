import Foundation

// Extension to add missing protocol methods to remaining CPU scenarios

public extension CPUOscillationScenario {
    func setUp() async throws {
        // No specific setup needed
    }
    
    func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        try await execute(with: orchestrator)
    }
    
    func tearDown() async throws {
        // No specific teardown needed
    }
}

public extension MatrixComputationScenario {
    func setUp() async throws {
        // No specific setup needed
    }
    
    func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        try await execute(with: orchestrator)
    }
    
    func tearDown() async throws {
        // No specific teardown needed
    }
}

public extension RealisticAppLoadScenario {
    func setUp() async throws {
        // No specific setup needed
    }
    
    func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        try await execute(with: orchestrator)
    }
    
    func tearDown() async throws {
        // No specific teardown needed
    }
}
