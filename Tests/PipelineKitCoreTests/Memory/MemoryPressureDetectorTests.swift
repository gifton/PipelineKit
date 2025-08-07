import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class MemoryPressureDetectorTests: XCTestCase {
    override func tearDown() async throws {
        // Ensure monitor is stopped after each test
        await MemoryPressureDetector.shared.stopMonitoring()
        try await super.tearDown()
    }
    
    // MARK: - Singleton Tests
    
    func testSharedInstanceIsSingleton() {
        // Given/When
        let instance1 = MemoryPressureDetector.shared
        let instance2 = MemoryPressureDetector.shared
        
        // Then
        XCTAssertTrue(instance1 === instance2, "Should return same instance")
    }
    
    // MARK: - Monitoring State Tests
    
    func testStartMonitoring() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        
        // When
        await monitor.startMonitoring()
        
        // Then - Should be able to get pressure level
        let level = await monitor.pressureLevel
        XCTAssertNotNil(level)
        XCTAssertEqual(level, .normal, "Should start with normal pressure")
    }
    
    func testStopMonitoring() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        await monitor.startMonitoring()
        
        // When
        await monitor.stopMonitoring()
        
        // Then - Should still be able to query state
        let level = await monitor.pressureLevel
        XCTAssertNotNil(level)
    }
    
    func testMultipleStartCalls() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        
        // When - Start multiple times
        await monitor.startMonitoring()
        await monitor.startMonitoring()
        await monitor.startMonitoring()
        
        // Then - Should handle gracefully
        let stats = await monitor.statistics
        XCTAssertNotNil(stats)
        
        // Cleanup
        await monitor.stopMonitoring()
    }
    
    func testMultipleStopCalls() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        await monitor.startMonitoring()
        
        // When - Stop multiple times
        await monitor.stopMonitoring()
        await monitor.stopMonitoring()
        await monitor.stopMonitoring()
        
        // Then - Should handle gracefully
        let level = await monitor.pressureLevel
        XCTAssertNotNil(level)
    }
    
    // MARK: - Handler Registration Tests
    
    func testRegisterHandler() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        let expectation = XCTestExpectation(description: "Handler called")
        expectation.isInverted = true // Should NOT be called in this test
        
        // When
        let id = await monitor.register {
            expectation.fulfill()
        }
        
        // Then
        XCTAssertNotNil(id)
        await fulfillment(of: [expectation], timeout: 0.1)
    }
    
    func testUnregisterHandler() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        let id = await monitor.register {
            // Handler that should be removed
        }
        
        // When
        await monitor.unregister(id: id)
        
        // Then - Handler is removed (no direct way to test, but should not crash)
        let stats = await monitor.statistics
        XCTAssertNotNil(stats)
    }
    
    func testUnregisterNonExistentHandler() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        let fakeId = UUID()
        
        // When/Then - Should handle gracefully
        await monitor.unregister(id: fakeId)
    }
    
    func testMultipleHandlerRegistration() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        var handlerIds: [UUID] = []
        
        // When - Register multiple handlers
        for _ in 0..<10 {
            let id = await monitor.register {
                // Handler logic
            }
            handlerIds.append(id)
        }
        
        // Then
        XCTAssertEqual(handlerIds.count, 10)
        XCTAssertEqual(Set(handlerIds).count, 10, "All IDs should be unique")
        
        // Cleanup
        for id in handlerIds {
            await monitor.unregister(id: id)
        }
    }
    
    // MARK: - Statistics Tests
    
    func testInitialStatistics() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        
        // When
        let stats = await monitor.statistics
        
        // Then
        XCTAssertGreaterThanOrEqual(stats.systemWarnings, 0)
        XCTAssertGreaterThanOrEqual(stats.pressureEvents, 0)
        XCTAssertGreaterThanOrEqual(stats.periodicChecks, 0)
    }
    
    // MARK: - Pressure Level Tests
    
    func testPressureLevelValues() {
        // Test enum values
        XCTAssertEqual(MemoryPressureLevel.normal.rawValue, 0)
        XCTAssertEqual(MemoryPressureLevel.warning.rawValue, 1)
        XCTAssertEqual(MemoryPressureLevel.critical.rawValue, 2)
        
        // Test ordering
        XCTAssertLessThan(MemoryPressureLevel.normal.rawValue, MemoryPressureLevel.warning.rawValue)
        XCTAssertLessThan(MemoryPressureLevel.warning.rawValue, MemoryPressureLevel.critical.rawValue)
    }
    
    // MARK: - Application Lifecycle Tests
    
    func testSetupForApplication() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        
        // When
        await monitor.setupForApplication()
        
        // Then - Should be monitoring
        let level = await monitor.pressureLevel
        XCTAssertNotNil(level)
        
        // Cleanup
        await monitor.cleanupForApplication()
    }
    
    func testCleanupForApplication() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        await monitor.setupForApplication()
        
        // When
        await monitor.cleanupForApplication()
        
        // Then - Should stop monitoring
        let stats = await monitor.statistics
        XCTAssertNotNil(stats)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentRegistration() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        let registrationCount = 100
        
        // When - Register handlers concurrently
        let ids = await withTaskGroup(of: UUID.self) { group in
            for _ in 0..<registrationCount {
                group.addTask {
                    await monitor.register {
                        // Handler
                    }
                }
            }
            
            var collectedIds: [UUID] = []
            for await id in group {
                collectedIds.append(id)
            }
            return collectedIds
        }
        
        // Then
        XCTAssertEqual(ids.count, registrationCount)
        XCTAssertEqual(Set(ids).count, registrationCount, "All IDs should be unique")
    }
    
    func testConcurrentUnregistration() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        
        // Register handlers first
        var ids: [UUID] = []
        for _ in 0..<50 {
            let id = await monitor.register { }
            ids.append(id)
        }
        
        // When - Unregister concurrently
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await monitor.unregister(id: id)
                }
            }
        }
        
        // Then - Should complete without issues
        let stats = await monitor.statistics
        XCTAssertNotNil(stats)
    }
    
    func testConcurrentStateAccess() async throws {
        // Given
        let monitor = MemoryPressureDetector.shared
        await monitor.startMonitoring()
        
        // When - Access state concurrently
        await withTaskGroup(of: Void.self) { group in
            // Read pressure level
            for _ in 0..<50 {
                group.addTask {
                    _ = await monitor.pressureLevel
                }
            }
            
            // Read statistics
            for _ in 0..<50 {
                group.addTask {
                    _ = await monitor.statistics
                }
            }
        }
        
        // Then - Should complete without race conditions
        let finalLevel = await monitor.pressureLevel
        XCTAssertNotNil(finalLevel)
    }
}
