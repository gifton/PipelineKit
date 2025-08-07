import Foundation
@testable import PipelineKit
import PipelineKitTestSupport
@testable import StressTesting

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*
/// Pre-configured test contexts and utilities for common test scenarios.
public enum TestDefaults {
    
    // MARK: - Pre-configured Contexts
    
    /// Minimal context for quick unit tests
    public static func minimalContext() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.conservative)
            .withMockSafetyMonitor(violations: 0)
            .build()
    }
    
    /// Standard context with resource tracking
    public static func standardContext() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.balanced)
            .withMockSafetyMonitor()
            .withTestMetricCollector()
            .withResourceTracking()
            .withTimeControl(.real)
            .build()
    }
    
    /// Deterministic context for timing-sensitive tests
    public static func deterministicContext() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.balanced)
            .withMockSafetyMonitor()
            .withTestMetricCollector()
            .withTimeControl(.deterministic)
            .withResourceTracking()
            .isolationLevel(.isolated)
            .build()
    }
    
    /// Stress test context with high limits
    public static func stressContext() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.aggressive)
            .withMockSafetyMonitor()
            .withTestMetricCollector()
            .verboseLogging(true)
            .build()
    }
    
    /// Safety validation context
    public static func safetyValidationContext() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.conservative)
            .withMockSafetyMonitor(violations: 0)
            .withResourceTracking()
            .isolationLevel(.isolated)
            .build()
    }
    
    // MARK: - Mock Configurations
    
    /// Creates a safety monitor that will trigger violations
    public static func violatingSafetyMonitor(
        afterDuration: TimeInterval = 5.0,
        violationType: ViolationType = .memory
    ) -> MockSafetyMonitor {
        let monitor = MockSafetyMonitor()
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(afterDuration * 1_000_000_000))
            
            switch violationType {
            case .memory:
                monitor.configuredMemoryUsage = 0.95
                monitor.criticalViolationCount = 1
            case .cpu:
                monitor.configuredCPUUsage = 0.95
                monitor.criticalViolationCount = 1
            case .multiple:
                monitor.configuredMemoryUsage = 0.95
                monitor.configuredCPUUsage = 0.95
                monitor.criticalViolationCount = 2
            }
        }
        
        return monitor
    }
    
    public enum ViolationType: Sendable {
        case memory
        case cpu
        case fileDescriptor
        case custom
        case multiple
    }
    
    // MARK: - Safety Limits
    
    public struct SafetyLimits {
        public static let maxFileDescriptors: Int = 1000
        public static let maxMemory: Int = 1024 * 1024 * 1024 // 1GB
        public static let maxCPU: Double = 100.0
    }
    
    // MARK: - Test Utilities
    
    /// Runs a test with automatic resource leak detection
    public static func runWithLeakDetection<T>(
        context: TestContext? = nil,
        operation: (TestContext) async throws -> T
    ) async throws -> T {
        let testContext = context ?? standardContext()
        
        defer {
            Task {
                try? await testContext.verifyNoLeaks()
                await testContext.reset()
            }
        }
        
        return try await operation(testContext)
    }
    
    /// Runs a test with timeout
    public static func runWithTimeout<T>(
        _ timeout: TimeInterval,
        context: TestContext? = nil,
        operation: (TestContext) async throws -> T
    ) async throws -> T {
        let testContext = context ?? standardContext()
        
        return try await testContext.timeController.withTimeout(timeout) {
            try await operation(testContext)
        }
    }
    
    /// Runs a test with deterministic time
    public static func runWithDeterministicTime<T>(
        operation: (TestContext, MockTimeController) async throws -> T
    ) async throws -> T {
        let context = deterministicContext()
        guard let mockTime = context.timeController as? MockTimeController else {
            throw TestError.invalidConfiguration("Expected mock time controller")
        }
        
        return try await operation(context, mockTime)
    }
    
    // MARK: - Common Test Scenarios
    
    /// Creates a pre-configured CPU load scenario for testing
    public static func testCPUScenario(
        pattern: CPULoadPattern = .constant(percentage: 0.5),
        duration: TimeInterval = 5.0
    ) -> CPULoadScenario {
        CPULoadScenario(
            pattern: pattern,
            duration: duration,
            cores: 2
        )
    }
    
    /// Creates a pre-configured memory scenario for testing
    public static func testMemoryScenario(
        targetPercentage: Double = 0.3,
        duration: TimeInterval = 5.0
    ) -> BasicMemoryScenario {
        BasicMemoryScenario(
            targetPercentage: targetPercentage,
            duration: duration,
            allocationPattern: .gradual(steps: 5)
        )
    }
    
    /// Creates a pre-configured burst scenario for testing
    public static func testBurstScenario() -> BurstLoadScenario {
        BurstLoadScenario(
            name: "TestBurst",
            idleDuration: 1.0,
            spikeDuration: 2.0,
            recoveryDuration: 1.0,
            spikeIntensity: BurstLoadScenario.LoadIntensity(
                cpu: 0.7,
                memory: 0.5,
                concurrency: 50,
                resources: 0.3
            )
        )
    }
}

// MARK: - Test Error Extensions

extension TestError {
    static func invalidConfiguration(_ message: String) -> TestError {
        .safetyViolation("Invalid test configuration: \(message)")
    }
}

// MARK: - Common Test Assertions

/// Asserts that a scenario completes successfully
public func XCTAssertScenarioSucceeds(
    _ scenario: any StressScenario,
    using context: TestContext,
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        let orchestrator = context.createOrchestrator()
        let result = try await orchestrator.execute(scenario)
        
        XCTAssertEqual(result.status, .passed, "Scenario should pass", file: file, line: line)
        XCTAssertTrue(result.errors.isEmpty, "Scenario should have no errors", file: file, line: line)
    } catch {
        XCTFail("Scenario failed with error: \(error)", file: file, line: line)
    }
}

/// Asserts that a scenario fails with expected error
public func XCTAssertScenarioFails(
    _ scenario: any StressScenario,
    using context: TestContext,
    expectedError: Error? = nil,
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        let orchestrator = context.createOrchestrator()
        let result = try await orchestrator.execute(scenario)
        
        if result.status == .passed {
            XCTFail("Expected scenario to fail, but it passed", file: file, line: line)
        }
    } catch {
        // Expected to throw
        if let expectedError = expectedError {
            // Could add more specific error matching here
            _ = expectedError // Silence warning
        }
    }
}

/// Asserts that safety limits are respected
public func XCTAssertSafetyLimitsRespected(
    during operation: () async throws -> Void,
    using monitor: MockSafetyMonitor,
    file: StaticString = #file,
    line: UInt = #line
) async throws {
    let initialViolations = monitor.criticalViolationCount
    
    try await operation()
    
    let finalViolations = monitor.criticalViolationCount
    XCTAssertEqual(
        initialViolations,
        finalViolations,
        "Safety violations occurred during operation",
        file: file,
        line: line
    )
}
*/

// Placeholder to prevent compilation errors
public enum TestDefaults {
    public enum ViolationType: Sendable {
        case memory
        case cpu
        case fileDescriptor
        case custom
        case multiple
    }
    
    public enum SafetyLimits {
        public static let maxFileDescriptors: Int = 1000
        public static let maxMemory: Int = 1024 * 1024 * 1024 // 1GB
        public static let maxCPU: Double = 100.0
    }
}
