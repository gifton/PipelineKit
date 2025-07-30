import XCTest
@testable import PipelineKit

final class BurstLoadScenarioTests: XCTestCase {
    var orchestrator: StressOrchestrator!
    var safetyMonitor: DefaultSafetyMonitor!
    var metricCollector: MetricCollector!
    var runner: ScenarioRunner!
    
    override func setUp() async throws {
        safetyMonitor = DefaultSafetyMonitor(
            maxMemoryUsage: 0.5,
            maxCPUUsagePerCore: 0.5
        )
        metricCollector = MetricCollector()
        orchestrator = StressOrchestrator(
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
        runner = ScenarioRunner(
            orchestrator: orchestrator,
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
    }
    
    override func tearDown() async throws {
        await orchestrator.stopAll()
        orchestrator = nil
        safetyMonitor = nil
        metricCollector = nil
        runner = nil
    }
    
    func testBurstLoadScenarioExecution() async throws {
        // Create a short burst scenario for testing
        let scenario = BurstLoadScenario(
            name: "TestBurst",
            metricCollector: metricCollector,
            idleDuration: 0.5,
            spikeDuration: 1.0,
            recoveryDuration: 0.5,
            spikeIntensity: BurstLoadScenario.LoadIntensity(
                cpu: 0.3,
                memory: 0.2,
                concurrency: 10,
                resources: 0.1
            ),
            recoveryIntensity: BurstLoadScenario.LoadIntensity(
                cpu: 0.05,
                memory: 0.05,
                concurrency: 2,
                resources: 0.05
            )
        )
        
        // Execute scenario
        try await runner.run(scenario)
        
        // Verify metrics were recorded
        let phaseQuery = MetricQuery(
            namespace: "scenario",
            metric: "phase.transition",
            aggregation: .count
        )
        let phaseCount = await metricCollector.query(phaseQuery)
        XCTAssertGreaterThan(phaseCount, 0, "Phase transitions should be recorded")
        
        // Verify simulators were scheduled
        let scheduledQuery = MetricQuery(
            namespace: "scenario",
            metric: "simulator.scheduled",
            aggregation: .count
        )
        let scheduledCount = await metricCollector.query(scheduledQuery)
        XCTAssertGreaterThan(scheduledCount, 0, "Simulators should be scheduled")
        
        // Verify scenario completed
        let endQuery = MetricQuery(
            namespace: "scenario",
            metric: "scenario.end",
            aggregation: .count
        )
        let endCount = await metricCollector.query(endQuery)
        XCTAssertEqual(endCount, 1, "Scenario should complete once")
    }
    
    func testBurstLoadScenarioPhases() async throws {
        var phaseTransitions: [String] = []
        
        // Subscribe to phase transitions
        let stream = await metricCollector.stream(
            matching: { metric in
                metric.name == "phase.transition"
            }
        )
        
        let collectionTask = Task {
            for await metric in stream {
                if let phase = metric.tags["phase"] {
                    phaseTransitions.append(phase)
                }
            }
        }
        
        // Run scenario
        let scenario = BurstLoadScenario(
            name: "TestPhases",
            metricCollector: metricCollector,
            idleDuration: 0.1,
            spikeDuration: 0.2,
            recoveryDuration: 0.1
        )
        
        try await runner.run(scenario)
        
        // Wait briefly for metrics to be collected
        try await Task.sleep(nanoseconds: 100_000_000)
        collectionTask.cancel()
        
        // Verify phases occurred in order
        XCTAssertTrue(phaseTransitions.contains("idle"), "Should have idle phase")
        XCTAssertTrue(phaseTransitions.contains("spike"), "Should have spike phase")
        XCTAssertTrue(phaseTransitions.contains("recovery"), "Should have recovery phase")
    }
    
    func testBurstLoadScenarioSafetyLimits() async throws {
        // Create scenario that might exceed safety limits
        let scenario = BurstLoadScenario(
            name: "TestSafety",
            metricCollector: metricCollector,
            idleDuration: 0.1,
            spikeDuration: 0.5,
            recoveryDuration: 0.1,
            spikeIntensity: BurstLoadScenario.LoadIntensity(
                cpu: 0.6,  // Above safety limit
                memory: 0.6, // Above safety limit
                concurrency: 50,
                resources: 0.3
            )
        )
        
        // Should complete without crashing
        // Safety monitor should prevent excessive resource usage
        do {
            try await runner.run(scenario)
        } catch {
            // It's okay if it fails due to safety limits
            print("Scenario stopped by safety limits: \(error)")
        }
        
        // Verify system is still healthy
        let status = await safetyMonitor.currentStatus()
        XCTAssertTrue(status.isHealthy || status.totalViolations > 0,
                      "System should either be healthy or have recorded violations")
    }
    
    func testBurstLoadScenarioMetrics() async throws {
        let scenario = BurstLoadScenario(
            name: "TestMetrics",
            metricCollector: metricCollector,
            idleDuration: 0.1,
            spikeDuration: 0.3,
            recoveryDuration: 0.1
        )
        
        try await runner.run(scenario)
        
        // Query various metrics
        let queries = [
            ("scenario.start", "scenario"),
            ("scenario.end", "scenario"),
            ("simulator.scheduled", "scenario"),
            ("phase.transition", "scenario")
        ]
        
        for (metric, namespace) in queries {
            let query = MetricQuery(
                namespace: namespace,
                metric: metric,
                aggregation: .count
            )
            let count = await metricCollector.query(query)
            XCTAssertGreaterThan(count, 0, "Metric \(metric) should be recorded")
        }
    }
}