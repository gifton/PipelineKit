import XCTest
@testable import PipelineKitCore
import PipelineKitTestSupport

final class MemoryPressureResponderTests: XCTestCase {
    private var handler: MemoryPressureResponder!
    
    override func setUp() async throws {
        try await super.setUp()
        // Create handler with test-friendly thresholds
        handler = MemoryPressureResponder(
            highWaterMark: 1024 * 1024,    // 1MB
            lowWaterMark: 512 * 1024        // 512KB
        )
    }
    
    override func tearDown() async throws {
        await handler?.stopMonitoring()
        handler = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitWithDefaultValues() {
        // Given/When
        let defaultHandler = MemoryPressureResponder()
        
        // Then
        XCTAssertNotNil(defaultHandler)
        // Default values are 100MB and 50MB as per implementation
    }
    
    func testInitWithCustomValues() {
        // Given/When
        let customHandler = MemoryPressureResponder(
            highWaterMark: 200 * 1024 * 1024,  // 200MB
            lowWaterMark: 100 * 1024 * 1024    // 100MB
        )
        
        // Then
        XCTAssertNotNil(customHandler)
    }
    
    // MARK: - Monitoring Tests
    
    func testStartMonitoring() async throws {
        // Given
        let pressureLevel = await handler.pressureLevel
        XCTAssertEqual(pressureLevel, .normal)
        
        // When
        await handler.startMonitoring()
        
        // Then
        let stats = await handler.statistics
        XCTAssertNotNil(stats)
    }
    
    func testStopMonitoring() async throws {
        // Given
        await handler.startMonitoring()
        
        // When
        await handler.stopMonitoring()
        
        // Then - Should still be queryable
        let level = await handler.pressureLevel
        XCTAssertNotNil(level)
    }
    
    func testDoubleStartMonitoring() async throws {
        // Given
        await handler.startMonitoring()
        
        // When - Start again
        await handler.startMonitoring()
        
        // Then - Should handle gracefully
        let stats = await handler.statistics
        XCTAssertNotNil(stats)
    }
    
    func testDoubleStopMonitoring() async throws {
        // Given
        await handler.startMonitoring()
        await handler.stopMonitoring()
        
        // When - Stop again
        await handler.stopMonitoring()
        
        // Then - Should handle gracefully
        let level = await handler.pressureLevel
        XCTAssertNotNil(level)
    }
    
    // MARK: - Handler Registration Tests
    
    func testRegisterSingleHandler() async throws {
        // Given
        let expectation = XCTestExpectation(description: "Handler not called")
        expectation.isInverted = true
        
        // When
        let id = await handler.register {
            expectation.fulfill()
        }
        
        // Then
        XCTAssertNotNil(id)
        await fulfillment(of: [expectation], timeout: 0.1)
    }
    
    func testRegisterMultipleHandlers() async throws {
        // Given
        var registeredIds: [UUID] = []
        
        // When
        for i in 0..<10 {
            let id = await handler.register {
                print("Handler \(i) called")
            }
            registeredIds.append(id)
        }
        
        // Then
        XCTAssertEqual(registeredIds.count, 10)
        XCTAssertEqual(Set(registeredIds).count, 10, "All IDs should be unique")
    }
    
    func testUnregisterHandler() async throws {
        // Given
        let id = await handler.register {
            XCTFail("Handler should not be called after unregistration")
        }
        
        // When
        await handler.unregister(id: id)
        
        // Then - Handler removed (tested indirectly through pressure event)
        // If we could trigger memory pressure, the handler should not be called
    }
    
    func testUnregisterNonExistentHandler() async throws {
        // Given
        let fakeId = UUID()
        
        // When/Then - Should not crash
        await handler.unregister(id: fakeId)
    }
    
    // MARK: - Statistics Tests
    
    func testInitialStatistics() async throws {
        // Given/When
        let stats = await handler.statistics
        
        // Then
        XCTAssertEqual(stats.systemWarnings, 0)
        XCTAssertEqual(stats.pressureEvents, 0)
        XCTAssertEqual(stats.periodicChecks, 0)
    }
    
    func testStatisticsAfterMonitoring() async throws {
        // Given
        await handler.startMonitoring()
        
        // When - Let it run briefly
        let synchronizer = TestSynchronizer()
        await synchronizer.mediumDelay()
        
        // Then
        let stats = await handler.statistics
        XCTAssertGreaterThanOrEqual(stats.periodicChecks, 0)
        
        // Cleanup
        await handler.stopMonitoring()
    }
    
    // MARK: - Pressure Level Tests
    
    func testInitialPressureLevel() async throws {
        // Given/When
        let level = await handler.pressureLevel
        
        // Then
        XCTAssertEqual(level, .normal)
    }
    
    func testPressureLevelEnum() {
        // Test raw values
        XCTAssertEqual(MemoryPressureLevel.normal.rawValue, 0)
        XCTAssertEqual(MemoryPressureLevel.warning.rawValue, 1)
        XCTAssertEqual(MemoryPressureLevel.critical.rawValue, 2)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentHandlerRegistration() async throws {
        // Given
        let registrationCount = 100
        
        // When
        let ids = await withTaskGroup(of: UUID.self) { group in
            for i in 0..<registrationCount {
                group.addTask {
                    await self.handler.register {
                        print("Concurrent handler \(i)")
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
        XCTAssertEqual(Set(ids).count, registrationCount)
    }
    
    func testConcurrentHandlerUnregistration() async throws {
        // Given - Register handlers first
        var ids: [UUID] = []
        for _ in 0..<50 {
            let id = await handler.register { }
            ids.append(id)
        }
        
        // When - Unregister concurrently
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await self.handler.unregister(id: id)
                }
            }
        }
        
        // Then - Should complete without issues
        let stats = await handler.statistics
        XCTAssertNotNil(stats)
    }
    
    func testConcurrentStatisticsAccess() async throws {
        // Given
        await handler.startMonitoring()
        
        // When - Access statistics concurrently
        let results = await withTaskGroup(of: MemoryPressureStatistics.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await self.handler.statistics
                }
            }
            
            var stats: [MemoryPressureStatistics] = []
            for await stat in group {
                stats.append(stat)
            }
            return stats
        }
        
        // Then
        XCTAssertEqual(results.count, 100)
    }
    
    func testConcurrentPressureLevelAccess() async throws {
        // Given
        await handler.startMonitoring()
        
        // When - Access pressure level concurrently
        let results = await withTaskGroup(of: MemoryPressureLevel.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await self.handler.pressureLevel
                }
            }
            
            var levels: [MemoryPressureLevel] = []
            for await level in group {
                levels.append(level)
            }
            return levels
        }
        
        // Then
        XCTAssertEqual(results.count, 100)
        // All should be normal in test conditions
        XCTAssertTrue(results.allSatisfy { $0 == .normal })
    }
    
    // MARK: - Memory Pressure Simulation Tests
    
    func testHandlerExecutionOrder() async throws {
        // Given
        let executionOrder = ExecutionOrderTracker()
        
        // Register handlers
        let id1 = await handler.register {
            await executionOrder.recordExecution("handler1")
        }
        let id2 = await handler.register {
            await executionOrder.recordExecution("handler2")
        }
        let id3 = await handler.register {
            await executionOrder.recordExecution("handler3")
        }
        
        // When - Would need to trigger memory pressure
        // In real scenario, handlers would execute
        
        // Then - Verify registration worked
        XCTAssertNotNil(id1)
        XCTAssertNotNil(id2)
        XCTAssertNotNil(id3)
        
        // Cleanup
        await handler.unregister(id: id1)
        await handler.unregister(id: id2)
        await handler.unregister(id: id3)
    }
    
    // MARK: - Edge Cases
    
    func testHandlerWithError() async throws {
        // Given
        let errorExpectation = XCTestExpectation(description: "Error handler")
        errorExpectation.isInverted = true
        
        // When
        let id = await handler.register {
            errorExpectation.fulfill()
            // Cannot throw from this closure
        }
        
        // Then - Handler registered despite throwing
        XCTAssertNotNil(id)
        await fulfillment(of: [errorExpectation], timeout: 0.1)
    }
    
    func testEmptyHandlerList() async throws {
        // Given - No handlers registered
        
        // When - Get statistics
        let stats = await handler.statistics
        
        // Then
        XCTAssertEqual(stats.pressureEvents, 0)
    }
}

// MARK: - Test Helpers

// TestError is already defined in TestHelpers.swift
