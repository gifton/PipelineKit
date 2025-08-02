import XCTest
import Foundation
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: These tests require PipelineKitStressTest types which have been
// moved to a separate package. They should be moved to that package's test suite.
final class AdvancedIntegrationTests: XCTestCase {
    
    func testPlaceholder() {
        // Placeholder test to prevent empty test class
        XCTAssertTrue(true)
    }
    
    /*
    
    // MARK: - Properties
    
    var harness: ScenarioTestHarness!
    
    // MARK: - Setup & Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        harness = ScenarioTestHarness()
    }
    
    override func tearDown() async throws {
        harness = nil
        // Ensure leak detector is reset between tests
        await ResourceLeakDetector.shared.reset()
        try await super.tearDown()
    }
    
    // MARK: - Violation Scheduling Tests
    
    func testScheduledViolations() async throws {
        // Create scenario that runs for 3 seconds
        let scenario = LongRunningScenario(
            name: "Violation Test",
            duration: 3.0
        )
        
        // Schedule violations at specific times
        let result = try await harness
            .withContext { builder in
                builder
                    .withMockSafetyMonitor()
                    .withTimeControl(.deterministic)
            }
            .withViolations(
                .memorySpike(after: 1.0),
                .cpuOverload(after: 2.0)
            )
            .run(scenario)
        
        // Validate violations occurred
        XCTAssertEqual(result.violations.count, 2, "Should have 2 violations")
        
        // Check violation types and timing
        let memoryViolation = result.violations.first { $0.type == .memory }
        let cpuViolation = result.violations.first { $0.type == .cpu }
        
        XCTAssertNotNil(memoryViolation, "Should have memory violation")
        XCTAssertNotNil(cpuViolation, "Should have CPU violation")
        
        // Verify timing (approximate due to execution overhead)
        if let memoryTime = memoryViolation?.triggeredAt.timeIntervalSince(result.startTime) {
            XCTAssertTrue(abs(memoryTime - 1.0) < 0.5, "Memory violation should occur around 1s")
        }
        
        if let cpuTime = cpuViolation?.triggeredAt.timeIntervalSince(result.startTime) {
            XCTAssertTrue(abs(cpuTime - 2.0) < 0.5, "CPU violation should occur around 2s")
        }
    }
    
    func testViolationPatterns() async throws {
        // Test different violation patterns
        let scenario = LongRunningScenario(
            name: "Pattern Test",
            duration: 5.0
        )
        
        let result = try await harness
            .withContext { builder in
                builder
                    .withMockSafetyMonitor()
                    .withTimeControl(.deterministic)
            }
            .withViolations(
                // Spike pattern - sudden violation
                .spike(type: .memory, delay: 1.0),
                
                // Oscillating pattern - varies between safe and violation
                .oscillating(
                    type: .cpu,
                    minSeverity: .low,
                    maxSeverity: .critical,
                    period: 2.0,
                    duration: 4.0
                ),
                
                // Gradual pattern - slowly increases to violation
                .gradual(
                    type: .fileDescriptor,
                    startSeverity: .none,
                    endSeverity: .high,
                    duration: 3.0
                )
            )
            .run(scenario)
        
        // Should have violations from all patterns
        XCTAssertTrue(result.violations.count >= 3, "Should have violations from patterns")
        
        // Check we have different types
        let violationTypes = Set(result.violations.map { $0.type })
        XCTAssertTrue(violationTypes.contains(.memory), "Should have memory violations")
        XCTAssertTrue(violationTypes.contains(.cpu), "Should have CPU violations")
        XCTAssertTrue(violationTypes.contains(.fileDescriptor), "Should have file descriptor violations")
        
        // Validate pattern characteristics
        let cpuViolations = result.violations.filter { $0.type == .cpu }
        if cpuViolations.count > 1 {
            // Oscillating should create multiple violations with varying severities
            let severities = Set(cpuViolations.map { $0.severity })
            XCTAssertTrue(severities.count > 1, "Oscillating pattern should vary severities")
        }
    }
    
    func testCustomViolationScheduling() async throws {
        // Test custom violation with specific parameters
        let scenario = MemoryIntensiveScenario(
            name: "Custom Violation Test",
            allocations: 5,
            duration: 3.0
        )
        
        let customViolation = ScheduledViolation(
            id: UUID(),
            type: .custom("TestViolation"),
            trigger: .pattern(.sine, duration: 2.0),
            severity: .medium,
            metadata: ["source": "test", "priority": "high"]
        )
        
        let result = try await harness
            .withContext { builder in
                builder.withMockSafetyMonitor()
            }
            .withViolations(customViolation)
            .run(scenario)
        
        // Find custom violation
        let customViolations = result.violations.filter { 
            if case .custom(let name) = $0.type {
                return name == "TestViolation"
            }
            return false
        }
        
        XCTAssertFalse(customViolations.isEmpty, "Should have custom violations")
        
        // Check metadata propagation
        if let violation = customViolations.first {
            XCTAssertEqual(violation.metadata["source"] as? String, "test")
            XCTAssertEqual(violation.metadata["priority"] as? String, "high")
        }
    }
    
    // MARK: - Leak Detection Tests
    
    func testBasicLeakDetection() async throws {
        // Create scenario that intentionally leaks
        let scenario = LeakingScenario(
            name: "Leak Test",
            leakCount: 3,
            leakSize: 1024
        )
        
        let result = try await harness
            .withLeakDetection()
            .run(scenario)
        
        // Should detect leaks
        XCTAssertFalse(result.hasLeaks, "Should not have leaks in execution result (detected separately)")
        
        // Check global leak detector
        let report = await ResourceLeakDetector.shared.generateReport(format: .text)
        XCTAssertTrue(report.contains("Total Leaks:"), "Report should include leak count")
    }
    
    func testCrossTestLeakDetection() async throws {
        // First test - create some leaks
        let leakingScenario = LeakingScenario(
            name: "Leaking Test",
            leakCount: 2,
            leakSize: 2048
        )
        
        _ = try await harness
            .withLeakDetection()
            .run(leakingScenario)
        
        // Second test - should detect previous leaks
        let cleanScenario = MemoryAllocationScenario(
            name: "Clean Test",
            targetMemory: 1000,
            duration: 0.1
        )
        
        let result2 = try await harness
            .withLeakDetection()
            .run(cleanScenario)
        
        // The clean scenario itself shouldn't leak
        XCTAssertTrue(result2.validate().hasNoLeaks(), "Clean scenario should not leak")
        
        // But global detector should have recorded leaks from first test
        let globalLeaks = await ResourceLeakDetector.shared.allLeaks()
        XCTAssertTrue(globalLeaks.count >= 2, "Should detect leaks across tests")
        
        // Verify leak details
        let leakSizes = globalLeaks.map { $0.size ?? 0 }
        XCTAssertTrue(leakSizes.contains(2048), "Should have correct leak size")
    }
    
    func testLeakReporting() async throws {
        // Create scenario with identifiable leaks
        let scenario = TypedLeakingScenario(
            name: "Typed Leak Test",
            leakTypes: [
                (TestResource.self, 1),
                (ExpensiveResource.self, 2),
                (CyclicResource.self, 1)
            ]
        )
        
        _ = try await harness
            .withLeakDetection()
            .withContext { builder in
                builder.withResourceTracking()
            }
            .run(scenario)
        
        // Test different report formats
        let textReport = await ResourceLeakDetector.shared.generateReport(format: .text)
        let jsonReport = await ResourceLeakDetector.shared.generateReport(format: .json)
        let junitReport = await ResourceLeakDetector.shared.generateReport(format: .junit)
        
        // Validate text report
        XCTAssertTrue(textReport.contains("TestResource"), "Should include type names")
        XCTAssertTrue(textReport.contains("ExpensiveResource"), "Should include all types")
        XCTAssertTrue(textReport.contains("Stack Trace:"), "Should include stack traces")
        
        // Validate JSON structure
        if let jsonData = jsonReport.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            XCTAssertNotNil(json["leaks"], "JSON should have leaks array")
            XCTAssertNotNil(json["summary"], "JSON should have summary")
        }
        
        // Validate JUnit format
        XCTAssertTrue(junitReport.contains("<testsuite"), "Should be valid JUnit XML")
        XCTAssertTrue(junitReport.contains("<testcase"), "Should have test cases")
    }
    
    // MARK: - Combined Tests
    
    func testViolationsAndLeaksTogether() async throws {
        // Scenario that both violates limits and leaks
        let scenario = ProblematicScenario(
            name: "Combined Problems",
            duration: 2.0,
            leakCount: 2,
            triggerViolations: true
        )
        
        let result = try await harness
            .withLeakDetection()
            .withPerformanceTracking()
            .withContext { builder in
                builder
                    .withMockSafetyMonitor()
                    .withResourceTracking()
            }
            .withViolations(
                .memorySpike(after: 0.5),
                .cpuOverload(after: 1.0)
            )
            .run(scenario)
        
        // Should have both violations and leaks
        XCTAssertTrue(result.hasViolations, "Should have violations")
        XCTAssertEqual(result.violations.count, 2, "Should have scheduled violations")
        
        // Check leak detection worked alongside violations
        let leaks = await ResourceLeakDetector.shared.leaksForTest(
            name: "AdvancedIntegrationTests.testViolationsAndLeaksTogether"
        )
        XCTAssertEqual(leaks.count, 2, "Should detect leaks even with violations")
        
        // Performance metrics should still be collected
        XCTAssertNotNil(result.metrics.averageCPU, "Should have CPU metrics")
        XCTAssertNotNil(result.metrics.peakMemory, "Should have memory metrics")
        
        // Summary should include all issues
        let summary = result.summary()
        XCTAssertTrue(summary.contains("Violations:"), "Summary should include violations")
        XCTAssertTrue(summary.contains("Memory Leaks:"), "Summary should include leaks")
    }
}

// MARK: - Test Scenarios

/// Long-running scenario for testing timed violations
private struct LongRunningScenario: StressScenario {
    let name: String
    let duration: TimeInterval
    
    var description: String { name }
    var timeout: TimeInterval { duration * 1.5 }
    var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    func setUp() async throws {}
    
    func execute(context: StressContext) async throws {
        // Just wait for the duration
        if let testContext = context as? TestContext,
           let mockTime = testContext.timeController as? MockTimeController {
            // Advance time in steps to trigger scheduled violations
            let steps = Int(duration)
            for _ in 0..<steps {
                await mockTime.advance(by: 1.0)
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        } else {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
    }
    
    func tearDown() async throws {}
}

/// Scenario that intentionally leaks memory
private struct LeakingScenario: StressScenario {
    let name: String
    let leakCount: Int
    let leakSize: Int
    
    var description: String { name }
    var timeout: TimeInterval { 5.0 }
    var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    // Static storage to create leaks
    static var leakedObjects: [Any] = []
    
    func setUp() async throws {}
    
    func execute(context: StressContext) async throws {
        // Create objects that won't be released
        for i in 0..<leakCount {
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: leakSize,
                alignment: MemoryLayout<UInt8>.alignment
            )
            
            // Store in static array to prevent deallocation
            let data = Data(bytesNoCopy: buffer, count: leakSize, deallocator: .none)
            Self.leakedObjects.append(data)
            
            // Register with leak detector if available
            if let testContext = context as? TestContext,
               let tracker = testContext.resourceTracker {
                await tracker.track(data, metadata: [
                    "index": i,
                    "size": leakSize,
                    "purpose": "intentional_leak"
                ])
            }
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    }
    
    func tearDown() async throws {
        // Don't clean up - that's the point!
    }
}

/// Scenario with typed objects for leak detection
private struct TypedLeakingScenario: StressScenario {
    let name: String
    let leakTypes: [(Any.Type, Int)]
    
    var description: String { name }
    var timeout: TimeInterval { 5.0 }
    var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    static var leakedResources: [Any] = []
    
    func setUp() async throws {}
    
    func execute(context: StressContext) async throws {
        for (type, count) in leakTypes {
            for _ in 0..<count {
                let resource: Any
                
                switch type {
                case is TestResource.Type:
                    resource = TestResource()
                case is ExpensiveResource.Type:
                    resource = ExpensiveResource()
                case is CyclicResource.Type:
                    resource = CyclicResource()
                default:
                    continue
                }
                
                Self.leakedResources.append(resource)
                
                // Track with leak detector
                if let testContext = context as? TestContext,
                   let tracker = testContext.resourceTracker,
                   let object = resource as? AnyObject {
                    await tracker.track(object, metadata: [
                        "type": String(describing: type),
                        "intentional": true
                    ])
                }
            }
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    func tearDown() async throws {}
}

/// Memory-intensive scenario with allocations
private struct MemoryIntensiveScenario: StressScenario {
    let name: String
    let allocations: Int
    let duration: TimeInterval
    
    var description: String { name }
    var timeout: TimeInterval { duration * 2 }
    var requiredResources: ResourceRequirements { 
        ResourceRequirements(memory: allocations * 1_000_000)
    }
    
    func setUp() async throws {}
    
    func execute(context: StressContext) async throws {
        var buffers: [UnsafeMutableRawPointer] = []
        
        // Allocate memory in chunks
        for _ in 0..<allocations {
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: 1_000_000,
                alignment: MemoryLayout<UInt8>.alignment
            )
            buffers.append(buffer)
            try await Task.sleep(nanoseconds: UInt64(duration / Double(allocations) * 1_000_000_000))
        }
        
        // Clean up
        for buffer in buffers {
            buffer.deallocate()
        }
    }
    
    func tearDown() async throws {}
}

/// Scenario that has both violations and leaks
private struct ProblematicScenario: StressScenario {
    let name: String
    let duration: TimeInterval
    let leakCount: Int
    let triggerViolations: Bool
    
    var description: String { name }
    var timeout: TimeInterval { duration * 2 }
    var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    static var problems: [Any] = []
    
    func setUp() async throws {}
    
    func execute(context: StressContext) async throws {
        // Create leaks
        for i in 0..<leakCount {
            let resource = ExpensiveResource()
            Self.problems.append(resource)
            
            if let testContext = context as? TestContext,
               let tracker = testContext.resourceTracker {
                await tracker.track(resource, metadata: ["leak": i])
            }
        }
        
        // Trigger violations through high resource usage
        if triggerViolations {
            // This would naturally trigger violations if limits are set low enough
            var wastefulData: [Data] = []
            for _ in 0..<10 {
                wastefulData.append(Data(repeating: 0xFF, count: 1_000_000))
            }
            
            // CPU spike
            var result = 0.0
            for i in 0..<1_000_000 {
                result += Double(i).squareRoot()
            }
        }
        
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
    
    func tearDown() async throws {}
}

// MARK: - Test Resources

/// Simple test resource for leak detection
private class TestResource {
    let id = UUID()
    var data = Data(repeating: 0xAA, count: 1024)
    
    deinit {
        // Would print if actually released
    }
}

/// More expensive resource
private class ExpensiveResource {
    let id = UUID()
    var cache: [String: Data] = [:]
    
    init() {
        for i in 0..<10 {
            cache["item_\(i)"] = Data(repeating: UInt8(i), count: 10240)
        }
    }
}

/// Resource with cyclic reference
private class CyclicResource {
    let id = UUID()
    var next: CyclicResource?
    
    init() {
        // Create self-reference
        next = self
    }
}

// MARK: - ScheduledViolation Extensions

private extension ScheduledViolation {
    /// Creates a memory spike violation
    static func memorySpike(after delay: TimeInterval) -> ScheduledViolation {
        ScheduledViolation(
            id: UUID(),
            type: .memory,
            trigger: .afterDelay(delay),
            severity: .high
        )
    }
    
    /// Creates a CPU overload violation
    static func cpuOverload(after delay: TimeInterval) -> ScheduledViolation {
        ScheduledViolation(
            id: UUID(),
            type: .cpu,
            trigger: .afterDelay(delay),
            severity: .critical
        )
    }
    
    /// Creates a spike pattern violation
    static func spike(type: ViolationType, delay: TimeInterval) -> ScheduledViolation {
        ScheduledViolation(
            id: UUID(),
            type: type,
            trigger: .afterDelay(delay),
            severity: .critical
        )
    }
    
    /// Creates an oscillating pattern violation
    static func oscillating(
        type: ViolationType,
        minSeverity: ViolationSeverity,
        maxSeverity: ViolationSeverity,
        period: TimeInterval,
        duration: TimeInterval
    ) -> ScheduledViolation {
        ScheduledViolation(
            id: UUID(),
            type: type,
            trigger: .pattern(.oscillating(
                min: minSeverity,
                max: maxSeverity,
                period: period
            ), duration: duration),
            severity: maxSeverity
        )
    }
    
    /// Creates a gradual pattern violation
    static func gradual(
        type: ViolationType,
        startSeverity: ViolationSeverity,
        endSeverity: ViolationSeverity,
        duration: TimeInterval
    ) -> ScheduledViolation {
        ScheduledViolation(
            id: UUID(),
            type: type,
            trigger: .pattern(.gradual(
                start: startSeverity,
                end: endSeverity
            ), duration: duration),
            severity: endSeverity
        )
    }
}
*/
}
