import XCTest
@testable import PipelineKit
@testable import StressTesting

final class BasicStressTestTests: XCTestCase {
    func testSafetyMonitorInitialization() async throws {
        // Test that we can create a safety monitor
        let monitor = DefaultSafetyMonitor()
        
        // Verify it starts in healthy state
        let status = await monitor.currentStatus()
        XCTAssertTrue(status.isHealthy)
        XCTAssertEqual(status.criticalViolations, 0)
        XCTAssertTrue(status.warnings.isEmpty)
    }
    
    func testMetricCollectorCreation() async throws {
        // Test that we can create a metric collector
        let collector = MetricCollector()
        
        // Verify it initializes correctly
        XCTAssertNotNil(collector)
        
        // Test basic recording
        await collector.recordEvent("test.event")
    }
    
    func testResourceManagerInitialization() async throws {
        // Test that we can create a resource manager
        let manager = ResourceManager()
        
        // Verify basic functionality - register a simple resource
        let resourceId = try await manager.register(
            type: .memory,
            size: 1024,
            cleanup: { }
        )
        XCTAssertNotNil(resourceId)
        
        // Clean up
        try await manager.release(resourceId)
    }
    
    func testStressOrchestratorCreation() async throws {
        // Test that the orchestrator can be created
        let safetyMonitor = DefaultSafetyMonitor()
        let metricCollector = MetricCollector()
        let orchestrator = StressOrchestrator(
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector
        )
        
        XCTAssertNotNil(orchestrator)
    }
}
