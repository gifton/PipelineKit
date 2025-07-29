import XCTest
@testable import PipelineKit

final class MemoryPressureSimulatorTests: XCTestCase {
    
    private var orchestrator: StressOrchestrator!
    
    override func setUp() async throws {
        try await super.setUp()
        orchestrator = StressOrchestrator()
    }
    
    override func tearDown() async throws {
        await orchestrator.shutdown()
        orchestrator = nil
        try await super.tearDown()
    }
    
    func testBasicMemoryAllocation() async throws {
        // Given
        let simulator = await orchestrator.memorySimulator
        let allocationSize = 10_000_000  // 10MB
        
        // When
        try await simulator.burst(size: allocationSize, holdTime: 0.1)
        
        // Then
        let stats = await simulator.currentStats()
        XCTAssertEqual(stats.allocatedBuffers, 0, "All buffers should be released after burst")
        XCTAssertEqual(stats.totalAllocated, 0, "Total allocation should be zero after release")
    }
    
    func testGradualPressure() async throws {
        // Given
        let simulator = await orchestrator.memorySimulator
        let targetUsage = 0.1  // 10% - keep it low for testing
        
        // When
        let task = Task {
            try await simulator.applyGradualPressure(
                targetUsage: targetUsage,
                duration: 2.0,
                stepSize: 5_000_000  // 5MB steps
            )
        }
        
        // Give it time to allocate some memory
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
        
        // Then - check that some allocation happened
        let midStats = await simulator.currentStats()
        XCTAssertGreaterThan(midStats.totalAllocated, 0, "Should have allocated some memory")
        XCTAssertGreaterThan(midStats.allocatedBuffers, 0, "Should have some buffers")
        
        // Wait for completion
        try await task.value
        
        // Cleanup
        await simulator.releaseAll()
    }
    
    func testSafetyLimits() async throws {
        // Given
        let strictSafetyMonitor = StrictTestSafetyMonitor()
        let resourceManager = ResourceManager()
        let simulator = MemoryPressureSimulator(
            resourceManager: resourceManager,
            safetyMonitor: strictSafetyMonitor
        )
        
        // When/Then - should throw safety error
        do {
            try await simulator.burst(size: 1_000_000_000, holdTime: 1.0)  // 1GB
            XCTFail("Should have thrown safety limit error")
        } catch let error as SimulatorError {
            if case .safetyLimitExceeded = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
    
    func testMemoryFragmentation() async throws {
        // Given
        let simulator = await orchestrator.memorySimulator
        let totalSize = 20_000_000  // 20MB
        let fragmentCount = 20  // 1MB each
        
        // When
        try await simulator.createFragmentation(
            totalSize: totalSize,
            fragmentCount: fragmentCount
        )
        
        // Then
        let stats = await simulator.currentStats()
        XCTAssertEqual(stats.allocatedBuffers, fragmentCount, "Should have created all fragments")
        XCTAssertEqual(stats.totalAllocated, totalSize, "Total allocation should match requested")
        XCTAssertEqual(stats.averageBufferSize, totalSize / fragmentCount, "Average should be correct")
        
        // Cleanup
        await simulator.releaseAll()
    }
    
    func testMemoryScenarioExecution() async throws {
        // Given
        let scenario = BasicMemoryScenario(
            timeout: 30,
            configuration: .init(
                targetUsage: 0.05,  // 5% - very low for testing
                rampUpDuration: 1.0,
                holdDuration: 1.0,
                createFragmentation: true
            )
        )
        
        // When
        let result = try await orchestrator.execute(scenario)
        
        // Then
        XCTAssertEqual(result.status, .passed, "Scenario should pass")
        XCTAssertTrue(result.errors.isEmpty, "Should have no errors")
        XCTAssertGreaterThan(result.peakMetrics.memoryUsage, result.baselineMetrics.memoryUsage, 
                            "Peak memory should be higher than baseline")
    }
    
    func testConcurrentSimulators() async throws {
        // Test that multiple simulators can be accessed concurrently
        async let sim1 = orchestrator.memorySimulator
        async let sim2 = orchestrator.memorySimulator
        
        let simulator1 = await sim1
        let simulator2 = await sim2
        
        // They should be the same instance (lazy initialization)
        XCTAssertTrue(simulator1 === simulator2, "Should return same simulator instance")
    }
}

// MARK: - Test Helpers

/// Strict safety monitor for testing that always denies large allocations.
private actor StrictTestSafetyMonitor: SafetyMonitor {
    func canAllocateMemory(_ bytes: Int) async -> Bool {
        bytes < 50_000_000  // Only allow allocations under 50MB
    }
    
    func canUseCPU(percentage: Double, cores: Int) async -> Bool {
        true
    }
    
    func checkSystemHealth() async -> [SafetyWarning] {
        []
    }
    
    func emergencyShutdown() async {
        // No-op for tests
    }
}