import XCTest
import Foundation
@testable import PipelineKit

final class OrchestratorSimulatorTests: XCTestCase {
    var orchestrator: StressOrchestrator!
    var metricCollector: TestMetricCollector!
    var safetyMonitor: MockSafetyMonitor!
    
    override func setUp() async throws {
        metricCollector = TestMetricCollector()
        safetyMonitor = MockSafetyMonitor()
        
        orchestrator = await StressOrchestrator(
            metricCollector: metricCollector,
            safetyMonitor: safetyMonitor,
            configuration: StressOrchestrator.Configuration()
        )
        
        await orchestrator.start()
    }
    
    override func tearDown() async throws {
        await orchestrator.stopAll()
        orchestrator = nil
        metricCollector = nil
        safetyMonitor = nil
    }
    
    // MARK: - CPU Simulator Integration
    
    func testCPUSimulatorLifecycle() async throws {
        // Schedule CPU load
        let scenario = CPULoadScenario(
            pattern: .constant(percentage: 50.0),
            cores: 2,
            duration: 2.0
        )
        
        let id = try await orchestrator.schedule(scenario)
        
        // Verify it's running
        let status = await orchestrator.status(for: id)
        XCTAssertNotNil(status, "Should have status for scheduled simulation")
        XCTAssertEqual(status?.state, .running, "Simulation should be running")
        
        // Wait for completion
        try await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
        
        // Should be completed
        let finalStatus = await orchestrator.status(for: id)
        XCTAssertNil(finalStatus, "Completed simulation should be removed")
        
        // Verify metrics
        await metricCollector.assertEventRecorded("simulation.started", withTags: ["type": "cpu"])
        await metricCollector.assertEventRecorded("simulation.completed", withTags: ["type": "cpu"])
    }
    
    func testCPUSimulatorCancellation() async throws {
        // Schedule long-running CPU load
        let scenario = CPULoadScenario(
            pattern: .constant(percentage: 70.0),
            cores: 4,
            duration: 10.0  // Long duration
        )
        
        let id = try await orchestrator.schedule(scenario)
        
        // Let it run briefly
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Stop it
        await orchestrator.stop(id)
        
        // Verify it's stopped
        let status = await orchestrator.status(for: id)
        XCTAssertNil(status, "Stopped simulation should be removed")
        
        // Verify cancellation metrics
        let events = await metricCollector.getRecordedEvents()
        let hasStopped = events.contains { $0.name == "simulation.stopped" }
        XCTAssertTrue(hasStopped, "Should record simulation stopped")
    }
    
    // MARK: - Memory Simulator Integration
    
    func testMemorySimulatorIntegration() async throws {
        // Schedule memory pressure
        let scenario = MemoryPressureScenario(
            targetUsage: 60.0,
            pattern: .gradual,
            duration: 3.0
        )
        
        let id = try await orchestrator.schedule(scenario)
        
        // Verify it's running
        let status = await orchestrator.status(for: id)
        XCTAssertEqual(status?.state, .running)
        
        // Wait for completion
        try await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
        
        // Verify metrics
        await metricCollector.assertEventRecorded("simulation.completed", withTags: ["type": "memory"])
        await metricCollector.assertMetricRecorded(name: "stress.memory.usage", type: .gauge)
    }
    
    // MARK: - Concurrent Simulations
    
    func testConcurrentSimulations() async throws {
        // Schedule multiple simulations
        let cpuScenario = CPULoadScenario(
            pattern: .constant(percentage: 30.0),
            cores: 1,
            duration: 2.0
        )
        
        let memoryScenario = MemoryPressureScenario(
            targetUsage: 40.0,
            pattern: .burst,
            duration: 2.0
        )
        
        let concurrencyScenario = ConcurrencyScenario(
            taskCount: 50,
            pattern: .sustained,
            duration: 2.0
        )
        
        // Schedule all three
        let cpuId = try await orchestrator.schedule(cpuScenario)
        let memId = try await orchestrator.schedule(memoryScenario)
        let concId = try await orchestrator.schedule(concurrencyScenario)
        
        // All should be running
        let orchestratorStatus = await orchestrator.currentStatus()
        XCTAssertEqual(orchestratorStatus.activeSimulations, 3, "Should have 3 active simulations")
        
        // Wait for completion
        try await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
        
        // All should be completed
        let finalStatus = await orchestrator.currentStatus()
        XCTAssertEqual(finalStatus.activeSimulations, 0, "All simulations should be completed")
        
        // Verify all types ran
        await metricCollector.assertEventRecorded("simulation.completed", withTags: ["type": "cpu"])
        await metricCollector.assertEventRecorded("simulation.completed", withTags: ["type": "memory"])
        await metricCollector.assertEventRecorded("simulation.completed", withTags: ["type": "concurrency"])
    }
    
    // MARK: - Safety Monitor Integration
    
    func testSafetyEnforcement() async throws {
        // Configure safety monitor to trigger after some time
        await safetyMonitor.setResourceUsage(cpu: 50.0)
        
        // Schedule CPU load that will push us over limit
        let scenario = CPULoadScenario(
            pattern: .constant(percentage: 80.0),
            cores: 2,
            duration: 5.0
        )
        
        let id = try await orchestrator.schedule(scenario)
        
        // After 1 second, trigger safety violation
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await safetyMonitor.setViolationTrigger(true, count: 2)
        
        // Wait a bit more
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Simulation should have been stopped due to safety
        let status = await orchestrator.status(for: id)
        XCTAssertNil(status, "Simulation should be stopped due to safety violation")
        
        // Verify safety metrics
        await metricCollector.assertEventRecorded("simulation.failed", withTags: ["type": "cpu"])
    }
    
    // MARK: - Resource Exhaustion
    
    func testResourceExhaustionHandling() async throws {
        // Schedule resource exhaustion
        let scenario = ResourceExhaustionScenario(
            targets: [
                ExhaustionTarget(
                    resource: .fileDescriptor,
                    amount: .percentage(80.0)
                )
            ],
            duration: 2.0
        )
        
        let id = try await orchestrator.schedule(scenario)
        
        // Wait for completion
        try await Task.sleep(nanoseconds: 2_500_000_000)
        
        // Verify proper cleanup
        let status = await orchestrator.currentStatus()
        XCTAssertEqual(status.activeSimulations, 0, "Resources should be cleaned up")
        
        // Verify metrics
        await metricCollector.assertEventRecorded("simulation.completed", withTags: ["type": "resource"])
    }
    
    // MARK: - Stop All Functionality
    
    func testStopAllSimulations() async throws {
        // Schedule multiple long-running simulations
        let scenarios = [
            CPULoadScenario(pattern: .constant(percentage: 40.0), cores: 1, duration: 10.0),
            CPULoadScenario(pattern: .wave(amplitude: 20.0, frequency: 1.0, offset: 50.0), cores: 2, duration: 10.0),
            MemoryPressureScenario(targetUsage: 50.0, pattern: .gradual, duration: 10.0)
        ]
        
        var ids: [UUID] = []
        for scenario in scenarios {
            if let cpuScenario = scenario as? CPULoadScenario {
                ids.append(try await orchestrator.schedule(cpuScenario))
            } else if let memScenario = scenario as? MemoryPressureScenario {
                ids.append(try await orchestrator.schedule(memScenario))
            }
        }
        
        // Verify all are running
        let initialStatus = await orchestrator.currentStatus()
        XCTAssertEqual(initialStatus.activeSimulations, 3)
        
        // Stop all
        await orchestrator.stopAll()
        
        // Verify all stopped
        let finalStatus = await orchestrator.currentStatus()
        XCTAssertEqual(finalStatus.activeSimulations, 0, "All simulations should be stopped")
        
        // Individual statuses should be nil
        for id in ids {
            let status = await orchestrator.status(for: id)
            XCTAssertNil(status, "Individual simulation should be removed")
        }
    }
    
    // MARK: - Metric Flow Validation
    
    func testMetricFlowFromSimulators() async throws {
        // Reset collector to ensure clean state
        await metricCollector.reset()
        
        // Run a simple CPU scenario
        let scenario = CPULoadScenario(
            pattern: .constant(percentage: 60.0),
            cores: 1,
            duration: 1.0
        )
        
        _ = try await orchestrator.schedule(scenario)
        
        // Wait for completion
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Verify metric flow
        let allMetrics = await metricCollector.getRecordedMetrics()
        
        // Should have various metrics
        let metricNames = Set(allMetrics.map(\.name))
        XCTAssertTrue(metricNames.contains("simulation.started"))
        XCTAssertTrue(metricNames.contains("stress.cpu.load"))
        XCTAssertTrue(metricNames.contains("simulation.completed"))
        
        // Verify metric types
        let loadMetrics = allMetrics.filter { $0.name == "stress.cpu.load" }
        XCTAssertTrue(loadMetrics.allSatisfy { $0.type == .gauge })
    }
    
    // MARK: - Error Handling
    
    func testInvalidScenarioHandling() async throws {
        // Create invalid scenario (negative duration)
        let scenario = CPULoadScenario(
            pattern: .constant(percentage: 50.0),
            cores: 1,
            duration: -1.0  // Invalid
        )
        
        do {
            _ = try await orchestrator.schedule(scenario)
            XCTFail("Should reject invalid scenario")
        } catch {
            // Expected error
            await metricCollector.assertEventRecorded("simulation.failed")
        }
    }
}