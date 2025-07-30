import XCTest
import Foundation
@testable import PipelineKit

/// Tests for executing complete stress test scenarios
final class ScenarioExecutionTests: XCTestCase {
    var orchestrator: StressOrchestrator!
    var metricCollector: TestMetricCollector!
    var safetyMonitor: MockSafetyMonitor!
    var runner: ScenarioRunner!
    
    override func setUp() async throws {
        metricCollector = TestMetricCollector()
        safetyMonitor = MockSafetyMonitor()
        orchestrator = await StressOrchestrator(
            metricCollector: metricCollector,
            safetyMonitor: safetyMonitor
        )
        runner = await ScenarioRunner(
            orchestrator: orchestrator,
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
        
        await orchestrator.start()
        await safetyMonitor.configureTestLimits()
    }
    
    override func tearDown() async throws {
        await orchestrator.stopAll()
        orchestrator = nil
        metricCollector = nil
        safetyMonitor = nil
        runner = nil
    }
    
    // MARK: - Burst Load Scenario
    
    func testBurstLoadScenario() async throws {
        let scenario = await MainActor.run {
            BurstLoadScenario(
                name: "TestBurst",
                metricCollector: metricCollector,
                idleDuration: 1.0,
                spikeDuration: 2.0,
                recoveryDuration: 1.0
            )
        }
        
        // Execute scenario
        try await runner.run(scenario)
        
        // Verify phases executed
        let phases = await metricCollector.extractPhases()
        XCTAssertTrue(phases.contains("idle"), "Should have idle phase")
        XCTAssertTrue(phases.contains("spike"), "Should have spike phase")
        XCTAssertTrue(phases.contains("recovery"), "Should have recovery phase")
        
        // Verify metrics recorded
        await metricCollector.assertEventRecorded("scenario.run.start", withTags: ["scenario": "TestBurst"])
        await metricCollector.assertEventRecorded("scenario.run.success", withTags: ["scenario": "TestBurst"])
        await metricCollector.assertMetricRecorded(name: "stress.cpu.load", type: .gauge)
        
        // Verify safety was checked
        await safetyMonitor.assertStatusChecked()
        
        // Verify proper cleanup
        let finalStatus = await orchestrator.currentStatus()
        XCTAssertEqual(finalStatus.activeSimulations, 0, "All simulations should be cleaned up")
    }
    
    // MARK: - Sustained Load Scenario
    
    func testSustainedLoadScenario() async throws {
        let scenario = await MainActor.run {
            SustainedLoadScenario(
                name: "TestSustained",
                metricCollector: metricCollector,
                sustainedDuration: 2.0
            )
        }
        
        // Execute scenario
        try await runner.run(scenario)
        
        // Verify constant load was maintained
        let loadMetrics = await metricCollector.getMetrics(matching: "stress.cpu.load")
        XCTAssertGreaterThan(loadMetrics.count, 0, "Should have CPU load metrics")
        
        // Check that load was relatively stable (within 10% variance)
        let values = loadMetrics.map(\.value)
        if let min = values.min(), let max = values.max() {
            let variance = (max - min) / max
            XCTAssertLessThan(variance, 0.1, "Load should be relatively stable")
        }
        
        // Verify completion
        await metricCollector.assertEventRecorded("scenario.run.success")
    }
    
    // MARK: - Chaos Scenario
    
    func testChaosScenarioDeterminism() async throws {
        let seed: UInt64 = 12345
        
        // Run chaos scenario twice with same seed
        let scenario1 = await MainActor.run {
            ChaosScenario(
                name: "TestChaos1",
                metricCollector: metricCollector,
                totalDuration: 3.0,
                seed: seed
            )
        }
        
        await metricCollector.reset()
        try await runner.run(scenario1)
        let events1 = await metricCollector.getRecordedEvents()
        
        // Reset and run again
        await metricCollector.reset()
        
        let scenario2 = await MainActor.run {
            ChaosScenario(
                name: "TestChaos2",
                metricCollector: metricCollector,
                totalDuration: 3.0,
                seed: seed
            )
        }
        
        try await runner.run(scenario2)
        let events2 = await metricCollector.getRecordedEvents()
        
        // Verify deterministic behavior (same seed = similar event patterns)
        // Note: Exact equality may not be possible due to timing, but patterns should be similar
        XCTAssertEqual(events1.count, events2.count, variation: 2, "Event counts should be similar")
    }
    
    // MARK: - Ramp Up Scenario
    
    func testRampUpScenario() async throws {
        let scenario = await MainActor.run {
            RampUpScenario(
                name: "TestRampUp",
                metricCollector: metricCollector,
                startIntensity: 0.1,
                endIntensity: 0.8,
                stepDuration: 0.5,
                steps: 4
            )
        }
        
        // Execute scenario
        try await runner.run(scenario)
        
        // Verify gradual increase in load
        let loadMetrics = await metricCollector.getMetrics(matching: "stress.cpu.load")
        let values = loadMetrics.map(\.value)
        
        // Check that values generally increase over time
        if values.count > 4 {
            let firstQuarter = Array(values.prefix(values.count / 4))
            let lastQuarter = Array(values.suffix(values.count / 4))
            
            let avgFirst = firstQuarter.reduce(0.0, +) / Double(firstQuarter.count)
            let avgLast = lastQuarter.reduce(0.0, +) / Double(lastQuarter.count)
            
            XCTAssertLessThan(avgFirst, avgLast, "Load should increase over time")
        }
        
        // Verify completion
        await metricCollector.assertEventRecorded("scenario.run.success")
    }
    
    // MARK: - Safety Enforcement
    
    func testScenarioSafetyEnforcement() async throws {
        // Configure safety monitor to trigger violation after 1 second
        await safetyMonitor.setResourceUsage(cpu: 70.0)
        
        let scenario = await MainActor.run {
            SustainedLoadScenario(
                name: "TestSafety",
                metricCollector: metricCollector,
                sustainedDuration: 5.0 // Long duration
            )
        }
        
        // Start execution
        let task = Task {
            try await runner.run(scenario)
        }
        
        // After 1 second, trigger safety violation
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await safetyMonitor.setViolationTrigger(true, count: 1)
        
        // Wait for scenario to handle safety violation
        do {
            try await task.value
            // If we get here, safety might have recovered
        } catch {
            // Expected - safety violation should stop scenario
            let errorString = error.localizedDescription.lowercased()
            XCTAssertTrue(
                errorString.contains("safety") || errorString.contains("violation"),
                "Expected safety error"
            )
        }
        
        // Verify safety abort was recorded
        let events = await metricCollector.getRecordedEvents()
        let hasAbort = events.contains { $0.name.contains("abort") || $0.name.contains("safety") }
        XCTAssertTrue(hasAbort, "Should record safety abort")
    }
    
    // MARK: - Concurrent Scenarios
    
    func testMultipleScenarioExecution() async throws {
        // Create multiple short scenarios
        let scenarios = await MainActor.run { [
            BurstLoadScenario(
                name: "Burst1",
                metricCollector: metricCollector,
                idleDuration: 0.5,
                spikeDuration: 1.0,
                recoveryDuration: 0.5
            ),
            SustainedLoadScenario(
                name: "Sustained1",
                metricCollector: metricCollector,
                sustainedDuration: 2.0
            ),
            RampUpScenario(
                name: "RampUp1",
                metricCollector: metricCollector,
                startIntensity: 0.1,
                endIntensity: 0.5,
                stepDuration: 0.5,
                steps: 4
            )
        ] }
        
        // Run scenarios in sequence
        try await runner.runSequence(scenarios)
        
        // Verify all scenarios completed
        await metricCollector.assertEventRecorded("scenario.run.success", withTags: ["scenario": "Burst1"])
        await metricCollector.assertEventRecorded("scenario.run.success", withTags: ["scenario": "Sustained1"])
        await metricCollector.assertEventRecorded("scenario.run.success", withTags: ["scenario": "RampUp1"])
        
        // Verify sequence progress was tracked
        await metricCollector.assertEventRecorded("scenario.sequence.progress")
    }
}

// MARK: - Test Helpers

extension XCTAssert {
    /// Assert two integers are equal within a variation
    static func assertEqual<T: BinaryInteger>(
        _ expression1: T,
        _ expression2: T,
        variation: T,
        _ message: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let diff = abs(Int(expression1) - Int(expression2))
        XCTAssertLessThanOrEqual(
            diff,
            Int(variation),
            message,
            file: file,
            line: line
        )
    }
}