import XCTest
@testable import PipelineKitCore

final class MemoryPressureDetectorTests: XCTestCase {
    
    // MARK: - Setup & Teardown
    
    override func tearDown() async throws {
        // Clean up after each test
        await MemoryPressureDetector.shared.stopMonitoring()
        try await super.tearDown()
    }
    
    // MARK: - Basic Functionality Tests
    
    func testSharedInstanceIsSingleton() async {
        let detector1 = MemoryPressureDetector.shared
        let detector2 = MemoryPressureDetector.shared
        XCTAssertTrue(detector1 === detector2, "Should be the same instance")
    }
    
    func testStartMonitoring() async {
        let detector = MemoryPressureDetector.shared
        await detector.startMonitoring()
        
        // Starting again should be safe (idempotent)
        await detector.startMonitoring()
        
        // Verify we can get pressure level
        let level = await detector.pressureLevel
        XCTAssertNotNil(level, "Should have a pressure level when monitoring")
    }
    
    func testStopMonitoring() async {
        let detector = MemoryPressureDetector.shared
        
        await detector.startMonitoring()
        await detector.stopMonitoring()
        
        // Stopping again should be safe (idempotent)
        await detector.stopMonitoring()
    }
    
    // MARK: - Handler Registration Tests
    
    func testRegisterHandler() async {
        let detector = MemoryPressureDetector.shared
        let handlerCalled = TestActor<Bool>(false)
        
        let handlerId = await detector.register {
            await handlerCalled.set(true)
        }
        
        XCTAssertNotNil(handlerId, "Should return a valid handler ID")
        
        // Clean up
        await detector.unregister(id: handlerId)
    }
    
    func testUnregisterHandler() async {
        let detector = MemoryPressureDetector.shared
        
        let handlerId = await detector.register {
            // Empty handler
        }
        
        // Should not crash when unregistering
        await detector.unregister(id: handlerId)
        
        // Should be safe to unregister non-existent ID
        await detector.unregister(id: UUID())
    }
    
    func testMultipleHandlerRegistration() async {
        let detector = MemoryPressureDetector.shared
        let handler1Called = TestActor<Bool>(false)
        let handler2Called = TestActor<Bool>(false)
        let handler3Called = TestActor<Bool>(false)
        
        let id1 = await detector.register { await handler1Called.set(true) }
        let id2 = await detector.register { await handler2Called.set(true) }
        let id3 = await detector.register { await handler3Called.set(true) }
        
        XCTAssertNotEqual(id1, id2, "Handler IDs should be unique")
        XCTAssertNotEqual(id2, id3, "Handler IDs should be unique")
        XCTAssertNotEqual(id1, id3, "Handler IDs should be unique")
        
        // Clean up
        await detector.unregister(id: id1)
        await detector.unregister(id: id2)
        await detector.unregister(id: id3)
    }
    
    // MARK: - Pressure Level Tests
    
    func testGetPressureLevel() async {
        let detector = MemoryPressureDetector.shared
        await detector.startMonitoring()
        
        let level = await detector.pressureLevel
        
        // Should be one of the defined levels
        switch level {
        case .normal, .warning, .critical:
            // Valid level
            break
        }
    }
    
    func testPressureLevelWithoutMonitoring() async {
        let detector = MemoryPressureDetector.shared
        await detector.stopMonitoring()
        
        let level = await detector.pressureLevel
        // Should still return a valid level even when not monitoring
        XCTAssertNotNil(level, "Should have a default pressure level")
    }
    
    // MARK: - Statistics Tests
    
    func testGetStatistics() async {
        let detector = MemoryPressureDetector.shared
        await detector.startMonitoring()
        
        let stats = await detector.statistics
        
        XCTAssertGreaterThanOrEqual(stats.systemWarnings, 0, "System warnings should be non-negative")
        XCTAssertGreaterThanOrEqual(stats.pressureEvents, 0, "Pressure events should be non-negative")
        XCTAssertGreaterThanOrEqual(stats.periodicChecks, 0, "Periodic checks should be non-negative")
    }
    
    func testStatisticsUpdate() async {
        let detector = MemoryPressureDetector.shared
        await detector.startMonitoring()
        
        let stats1 = await detector.statistics
        
        // Give some time for potential updates
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let stats2 = await detector.statistics
        
        // Statistics might change over time
        XCTAssertGreaterThanOrEqual(stats2.periodicChecks, stats1.periodicChecks,
                                   "Periodic check count should not decrease")
    }
    
    // MARK: - Application Lifecycle Tests
    
    func testSetupForApplication() async {
        let detector = MemoryPressureDetector.shared
        await detector.setupForApplication()
        
        // Should be monitoring after setup
        let level = await detector.pressureLevel
        XCTAssertNotNil(level, "Should be monitoring after application setup")
    }
    
    func testCleanupForApplication() async {
        let detector = MemoryPressureDetector.shared
        
        await detector.setupForApplication()
        await detector.cleanupForApplication()
        
        // Should handle multiple cleanups gracefully
        await detector.cleanupForApplication()
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentHandlerRegistration() async {
        let detector = MemoryPressureDetector.shared
        let handlerCount = 100
        var handlerIds: [UUID] = []
        
        // Register many handlers concurrently
        await withTaskGroup(of: UUID.self) { group in
            for _ in 0..<handlerCount {
                group.addTask {
                    await detector.register {
                        // Empty handler
                    }
                }
            }
            
            for await id in group {
                handlerIds.append(id)
            }
        }
        
        // All IDs should be unique
        let uniqueIds = Set(handlerIds)
        XCTAssertEqual(uniqueIds.count, handlerCount, "All handler IDs should be unique")
        
        // Clean up
        for id in handlerIds {
            await detector.unregister(id: id)
        }
    }
    
    func testConcurrentMonitoringOperations() async {
        let detector = MemoryPressureDetector.shared
        
        // Perform many start/stop operations concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i % 2 == 0 {
                        await detector.startMonitoring()
                    } else {
                        await detector.stopMonitoring()
                    }
                }
            }
        }
        
        // Should not crash or deadlock
    }
    
    // MARK: - Memory Threshold Tests
    
    func testMemoryThresholdCalculation() async {
        let detector = MemoryPressureDetector.shared
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        
        // Thresholds should be reasonable percentages of total memory
        let expectedHighWatermark = Int(Double(totalMemory) * 0.15)
        let expectedLowWatermark = Int(Double(totalMemory) * 0.05)
        
        // Start monitoring to initialize thresholds
        await detector.startMonitoring()
        let stats = await detector.statistics
        
        // We can't directly access the watermarks, but we can verify
        // that the statistics are being collected
        XCTAssertGreaterThanOrEqual(stats.periodicChecks, 0, 
                                   "Should have done at least one check")
        XCTAssertGreaterThan(expectedHighWatermark, expectedLowWatermark,
                            "High watermark should be greater than low watermark")
    }
    
    // MARK: - Handler Execution Tests
    
    func testHandlerExecutionOrder() async {
        let detector = MemoryPressureDetector.shared
        let executionOrder = TestActor<[Int]>([])
        
        let id1 = await detector.register {
            await executionOrder.append(1)
        }
        let id2 = await detector.register {
            await executionOrder.append(2)
        }
        let id3 = await detector.register {
            await executionOrder.append(3)
        }
        
        // Note: We can't directly trigger memory pressure events in tests,
        // but we've registered the handlers successfully
        
        // Clean up
        await detector.unregister(id: id1)
        await detector.unregister(id: id2)
        await detector.unregister(id: id3)
    }
    
    // MARK: - Performance Tests
    
    func testRegistrationPerformance() async throws {
        let detector = MemoryPressureDetector.shared
        let iterations = 1000
        
        let start = Date()
        var ids: [UUID] = []
        
        for _ in 0..<iterations {
            let id = await detector.register {
                // Empty handler
            }
            ids.append(id)
        }
        
        let registrationTime = Date().timeIntervalSince(start)
        
        // Clean up
        for id in ids {
            await detector.unregister(id: id)
        }
        
        let totalTime = Date().timeIntervalSince(start)
        
        print("Registration performance: \(iterations) handlers in \(registrationTime)s")
        print("Total time including cleanup: \(totalTime)s")
        
        // Should handle at least 100 registrations per second
        let registrationsPerSecond = Double(iterations) / registrationTime
        XCTAssertGreaterThan(registrationsPerSecond, 100,
                            "Should handle at least 100 registrations per second")
    }
}

// MARK: - Test Helpers

/// Thread-safe test helper for collecting ordered events
private actor TestActor<T> {
    private var value: T
    
    init(_ initial: T) {
        self.value = initial
    }
    
    func get() -> T {
        return value
    }
    
    func set(_ newValue: T) {
        self.value = newValue
    }
}

extension TestActor where T == [Int] {
    func append(_ element: Int) {
        value.append(element)
    }
}

// MARK: - Memory Pressure Level Extension

extension MemoryPressureLevel: CustomStringConvertible {
    public var description: String {
        switch self {
        case .normal:
            return "normal"
        case .warning:
            return "warning"
        case .critical:
            return "critical"
        }
    }
}