import XCTest
import PipelineKitResilience
import PipelineKit
import PipelineKitTestSupport

/// Performance tests for BackPressure mechanisms
final class BackPressurePerformanceTests: XCTestCase {
    // MARK: - Uncontended Acquire Performance
    
    func testUncontendedAcquirePerformance() throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 1000)
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric()
        ]) {
            let expectation = expectation(description: "Uncontended acquire")
            expectation.expectedFulfillmentCount = 10000
            
            Task {
                for _ in 0..<10000 {
                    let token = try await semaphore.acquire()
                    _ = token // Token releases on deallocation
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Try Acquire Performance
    
    func testTryAcquirePerformance() throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 100)
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric()
        ]) {
            let expectation = expectation(description: "Try acquire")
            expectation.expectedFulfillmentCount = 10000
            
            Task {
                for _ in 0..<10000 {
                    if let token = await semaphore.tryAcquire() {
                        _ = token
                    }
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Contended Access Performance
    
    func testContendedAccessPerformance() throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 10)
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Contended access")
            expectation.expectedFulfillmentCount = 1000
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<1000 {
                        group.addTask {
                            if let token = try? await semaphore.acquire() {
                                // Simulate some work
                                _ = (0..<10).reduce(0, +)
                                _ = token
                            }
                            expectation.fulfill()
                        }
                    }
                }
            }
            
            wait(for: [expectation], timeout: 15)
        }
    }
    
    // MARK: - High Concurrency Performance
    
    func testHighConcurrencyPerformance() throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 100)
        
        let options = XCTMeasureOptions()
        options.iterationCount = 5  // Fewer iterations for high concurrency test
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ], options: options) {
            let expectation = expectation(description: "High concurrency")
            expectation.expectedFulfillmentCount = 1000
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    // Create 1000 concurrent tasks
                    for _ in 0..<1000 {
                        group.addTask {
                            if let token = try? await semaphore.acquire() {
                                _ = token
                            }
                            expectation.fulfill()
                        }
                    }
                }
            }
            
            wait(for: [expectation], timeout: 20)
        }
    }
    
    // MARK: - Failed Acquire Performance
    
    func testFailedAcquirePerformance() throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 1)
        
        // Block the semaphore first
        let blockExpectation = expectation(description: "Block semaphore")
        let blockerTask = Task { @Sendable () -> SemaphoreToken? in
            let token = try? await semaphore.acquire()
            blockExpectation.fulfill()
            return token
        }
        wait(for: [blockExpectation], timeout: 1)

        // Clean up the blocker token after the test
        defer {
            blockerTask.cancel()
            Task { @Sendable in
                if let token = await blockerTask.value {
                    token.release()
                }
            }
        }
        
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric()
        ], options: options) {
            let expectation = expectation(description: "Failed acquire")
            expectation.expectedFulfillmentCount = 1000
            
            Task { @Sendable in
                for _ in 0..<1000 {
                    // tryAcquire should return nil immediately since semaphore is blocked
                    _ = await semaphore.tryAcquire()
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Memory Pressure Test
    
    func testMemoryPressureWithManyTokens() throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 10000)
        
        measure(metrics: [XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "Memory pressure")
            
            Task { @Sendable in
                var tokens: [SemaphoreToken] = []

                // Acquire many tokens
                for _ in 0..<5000 {
                    if let token = try? await semaphore.acquire() {
                        tokens.append(token)
                    }
                }
                
                // Release them all
                tokens.removeAll()
                
                expectation.fulfill()
            }
            
            self.wait(for: [expectation], timeout: 10)
        }
    }
}
