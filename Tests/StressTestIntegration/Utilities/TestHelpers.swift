import Foundation
import XCTest
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*
// MARK: - Test Configuration

public struct TestConfig {
    public let cpuSpike: Double
    public let memorySpike: Double
    public let duration: TimeInterval
    public let safetyFactor: Double
    
    public init(
        cpuSpike: Double = 80.0,
        memorySpike: Double = 60.0,
        duration: TimeInterval = 30.0,
        safetyFactor: Double = 0.9
    ) {
        self.cpuSpike = cpuSpike
        self.memorySpike = memorySpike
        self.duration = duration
        self.safetyFactor = safetyFactor
    }
}

// MARK: - Scenario Test Result

public struct ScenarioTestResult {
    public let scenario: String
    public let phases: [String]
    public let peakCPU: Double
    public let peakMemory: Double
    public let duration: TimeInterval
    public let crashed: Bool
    public let errors: [Error]
    
    public func hasPhase(_ phase: String) -> Bool {
        phases.contains(phase)
    }
}

// MARK: - Test Runner Extensions

public extension XCTestCase {
    /// Run a scenario with test configuration
    func runScenarioTest(
        scenario: any StressScenario,
        config: TestConfig,
        safetyLimits: SafetyConfiguration? = nil
    ) async throws -> ScenarioTestResult {
        let collector = TestMetricCollector()
        let monitor = MockSafetyMonitor()
        let orchestrator = await StressOrchestrator(
            metricCollector: collector,
            safetyMonitor: monitor
        )
        
        // Configure safety limits if provided
        if let safetyLimits = safetyLimits {
            await monitor.configure(safetyLimits)
        } else {
            await monitor.setResourceUsage(
                cpu: config.cpuSpike * config.safetyFactor,
                memory: config.memorySpike * config.safetyFactor
            )
        }
        
        let startTime = Date()
        var errors: [Error] = []
        var crashed = false
        
        do {
            try await scenario.execute(
                orchestrator: orchestrator,
                safetyMonitor: monitor,
                metricCollector: collector
            )
        } catch {
            errors.append(error)
            crashed = error is ScenarioError
        }
        
        let duration = Date().timeIntervalSince(startTime)
        let phases = await collector.extractPhases()
        let peakCPU = await collector.getPeakValue(for: "stress.cpu.load") ?? 0.0
        let peakMemory = await collector.getPeakValue(for: "stress.memory.usage") ?? 0.0
        
        return ScenarioTestResult(
            scenario: scenario.name,
            phases: phases,
            peakCPU: peakCPU,
            peakMemory: peakMemory,
            duration: duration,
            crashed: crashed,
            errors: errors
        )
    }
    
    /// Run a chaos scenario with deterministic seed
    func runChaosScenario(seed: UInt64) async throws -> ChaosTestResult {
        let scenario = ChaosScenario(
            name: "DeterministicChaos",
            metricCollector: TestMetricCollector(),
            totalDuration: 10.0,
            seed: seed
        )
        
        let collector = TestMetricCollector()
        let monitor = MockSafetyMonitor()
        let orchestrator = await StressOrchestrator(
            metricCollector: collector,
            safetyMonitor: monitor
        )
        
        try await scenario.execute(
            orchestrator: orchestrator,
            safetyMonitor: monitor,
            metricCollector: collector
        )
        
        let events = await collector.getRecordedEvents()
        let eventSequence = events.map(\.name)
        
        return ChaosTestResult(
            seed: seed,
            eventSequence: eventSequence,
            totalEvents: events.count
        )
    }
}

public struct ChaosTestResult: Equatable {
    public let seed: UInt64
    public let eventSequence: [String]
    public let totalEvents: Int
}

// MARK: - Async Test Helpers

public extension Task where Success == Never, Failure == Never {
    /// Sleep for a duration in seconds
    static func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Metric Validation Helpers

public extension TestMetricCollector {
    /// Verify that metrics show expected load patterns
    func verifyLoadPattern(
        expectedMin: Double,
        expectedMax: Double,
        metricName: String = "stress.cpu.load"
    ) async -> Bool {
        let metrics = getMetrics(matching: metricName)
        guard !metrics.isEmpty else { return false }
        
        let values = metrics.map(\.value)
        let min = values.min() ?? 0
        let max = values.max() ?? 0
        
        return min >= expectedMin && max <= expectedMax
    }
    
    /// Extract spike events from metrics
    func extractSpikes(
        threshold: Double,
        metricName: String = "stress.cpu.load"
    ) async -> [TimeInterval] {
        let metrics = getMetrics(matching: metricName)
        var spikeTimes: [TimeInterval] = []
        
        for metric in metrics where metric.value > threshold {
            spikeTimes.append(metric.timestamp.timeIntervalSinceReferenceDate)
        }
        
        return spikeTimes
    }
}

// MARK: - Safety Monitor Test Helpers

public extension MockSafetyMonitor {
    /// Configure typical test safety limits
    func configureTestLimits() async {
        await configure(SafetyConfiguration(
            checkInterval: 0.5,
            criticalThresholds: SafetyThresholds(
                cpu: 85.0,
                memory: 80.0,
                fileDescriptors: 900
            ),
            warningThresholds: SafetyThresholds(
                cpu: 70.0,
                memory: 65.0,
                fileDescriptors: 700
            )
        ))
    }
}
*/

// Placeholder types to prevent compilation errors
// SafetyConfiguration is defined in MockSafetyMonitor.swift
struct SafetyThresholds {
    init(cpu: Double, memory: Double, fileDescriptors: Int) {}
}