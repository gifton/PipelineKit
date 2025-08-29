import XCTest
import PipelineKitCore
import PipelineKitTestSupport

/// Performance tests for CommandContext operations
final class CommandContextPerformanceTests: XCTestCase {
    
    // MARK: - Set Metadata Performance
    
    func testSetMetadataPerformance() throws {
        let context = CommandContext()
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Set metadata")
            expectation.expectedFulfillmentCount = 10000
            
            Task {
                for i in 0..<10000 {
                    await context.setMetadata("key-\(i)", value: i)
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Get Metadata Performance
    
    func testGetMetadataPerformance() throws {
        let context = CommandContext()
        
        // Pre-populate context
        let setupExpectation = expectation(description: "Setup")
        Task {
            for i in 0..<100 {
                await context.setMetadata("key-\(i)", value: i)
            }
            setupExpectation.fulfill()
        }
        wait(for: [setupExpectation], timeout: 2)
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric()
        ]) {
            let expectation = expectation(description: "Get metadata")
            expectation.expectedFulfillmentCount = 10000
            
            Task {
                for i in 0..<10000 {
                    _ = await context.metadata["key-\(i % 100)"]
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Mixed Operations Performance
    
    func testMixedMetadataOperationsPerformance() throws {
        let context = CommandContext()
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Mixed operations")
            expectation.expectedFulfillmentCount = 10000
            
            Task {
                for i in 0..<10000 {
                    if i % 2 == 0 {
                        await context.setMetadata("key-\(i)", value: i)
                    } else {
                        _ = await context.metadata["key-\(i - 1)"]
                    }
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Concurrent Access Performance
    
    func testConcurrentMetadataAccessPerformance() throws {
        let context = CommandContext()
        
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Concurrent access")
            expectation.expectedFulfillmentCount = 10000
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    // 5000 writes
                    for i in 0..<5000 {
                        group.addTask {
                            await context.setMetadata("key-\(i)", value: i)
                            expectation.fulfill()
                        }
                    }
                    
                    // 5000 reads
                    for i in 0..<5000 {
                        group.addTask {
                            _ = await context.metadata["key-\(i)"]
                            expectation.fulfill()
                        }
                    }
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
    
    // MARK: - Create New Context Performance
    
    func testContextCreationPerformance() throws {
        measure(metrics: [
            XCTClockMetric(),
            XCTMemoryMetric()
        ]) {
            var contexts: [CommandContext] = []
            for _ in 0..<1000 {
                contexts.append(CommandContext())
            }
            // Prevent optimization
            XCTAssertEqual(contexts.count, 1000)
        }
    }
    
    // MARK: - Large Context Performance
    
    func testLargeContextPerformance() throws {
        let context = CommandContext()
        
        // Add a large amount of metadata
        let setupExpectation = expectation(description: "Setup large context")
        Task {
            for i in 0..<1000 {
                await context.setMetadata("key-\(i)", value: String(repeating: "data", count: 100))
            }
            setupExpectation.fulfill()
        }
        wait(for: [setupExpectation], timeout: 5)
        
        measure(metrics: [
            XCTClockMetric(),
            XCTMemoryMetric()
        ]) {
            let expectation = expectation(description: "Large context operations")
            expectation.expectedFulfillmentCount = 1000
            
            Task {
                for i in 0..<1000 {
                    if i % 2 == 0 {
                        _ = await context.metadata["key-\(i % 1000)"]
                    } else {
                        await context.setMetadata("new-key-\(i)", value: i)
                    }
                    expectation.fulfill()
                }
            }
            
            wait(for: [expectation], timeout: 10)
        }
    }
}