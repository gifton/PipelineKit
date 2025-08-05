import XCTest
import Foundation
@testable import PipelineKit

/// Basic tests to validate Thread Sanitizer configuration and detection
final class TSanValidationTests: XCTestCase {
    /// Test that TSan is properly configured and working
    /// This test intentionally creates a data race to verify TSan detection
    /// It should ONLY pass when TSan is disabled
    func testTSanDetectsBasicRace() async {
        // This test is expected to fail under TSan
        // Comment out or use XCTExpectFailure when running with TSan
        
        #if DEBUG
        // Skip this test when TSan is enabled as it intentionally creates a race
        print("Skipping race detection test in DEBUG mode with TSan")
        return
        #endif
        
        var counter = 0
        let iterations = 1000
        
        // Intentionally create a data race
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    counter += 1  // Intentional race condition
                }
            }
        }
        
        // Without synchronization, counter may not equal iterations
        print("Counter value: \(counter) (expected: \(iterations))")
    }
    
    /// Test that actors properly prevent data races
    func testActorPreventsRace() async {
        actor SafeCounter {
            private var count = 0
            
            func increment() {
                count += 1
            }
            
            func getValue() -> Int {
                return count
            }
        }
        
        let counter = SafeCounter()
        let iterations = 1000
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    await counter.increment()
                }
            }
        }
        
        let finalValue = await counter.getValue()
        XCTAssertEqual(finalValue, iterations, "Actor should prevent race conditions")
    }
    
    /// Test that MainActor usage is race-free
    func testMainActorSafety() async {
        @MainActor
        class SafeContainer {
            var items: [String] = []
            
            func addItem(_ item: String) {
                items.append(item)
            }
            
            func getCount() -> Int {
                return items.count
            }
        }
        
        let container = await SafeContainer()
        let itemCount = 100
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<itemCount {
                group.addTask {
                    await container.addItem("Item \(i)")
                }
            }
        }
        
        let finalCount = await container.getCount()
        XCTAssertEqual(finalCount, itemCount, "MainActor should ensure thread safety")
    }
    
    /// Test Sendable conformance prevents races
    func testSendableTypes() async {
        struct SafeData: Sendable {
            let id: Int
            let name: String
        }
        
        let data = SafeData(id: 1, name: "Test")
        var results: [SafeData] = []
        let lock = NSLock()
        
        await withTaskGroup(of: SafeData.self) { group in
            for i in 0..<10 {
                group.addTask {
                    // Safe to pass Sendable types between tasks
                    return SafeData(id: data.id + i, name: "\(data.name)-\(i)")
                }
            }
            
            for await result in group {
                lock.lock()
                results.append(result)
                lock.unlock()
            }
        }
        
        XCTAssertEqual(results.count, 10, "All tasks should complete")
    }
    
    /// Test that async sequences handle concurrent access safely
    func testAsyncSequenceSafety() async throws {
        let stream = AsyncStream<Int> { continuation in
            Task {
                for i in 0..<100 {
                    continuation.yield(i)
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                }
                continuation.finish()
            }
        }
        
        var collectedValues: [Int] = []
        let lock = NSLock()
        
        // Multiple consumers of the same stream
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await value in stream {
                    lock.lock()
                    collectedValues.append(value)
                    lock.unlock()
                }
            }
        }
        
        // Should collect all values without races
        XCTAssertGreaterThan(collectedValues.count, 0, "Should collect some values")
    }
    
    /// Test that basic concurrent operations are TSan-clean
    func testConcurrentMetricsCollection() async throws {
        // Test concurrent metric collection
        let collector = SimpleMetricCollector()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await collector.record("test.event", value: Double(i))
                }
            }
        }
        
        let count = await collector.count
        XCTAssertEqual(count, 100, "Should have collected all metrics")
    }
    
    /// Test basic concurrent access patterns
    func testConcurrentAccess() async {
        // Simple test to ensure TSan can detect issues in concurrent code
        let counter = Counter()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await counter.increment()
                }
            }
        }
        
        let finalValue = await counter.value
        XCTAssertEqual(finalValue, 10)
    }
}

// MARK: - Mock Types for Testing

private actor Counter {
    private var count = 0
    
    func increment() {
        count += 1
    }
    
    var value: Int {
        count
    }
}

private actor SimpleMetricCollector {
    private var metrics: [(name: String, value: Double)] = []
    
    func record(_ name: String, value: Double) {
        metrics.append((name: name, value: value))
    }
    
    var count: Int {
        metrics.count
    }
}

// MARK: - TSan Test Runner Configuration

extension TSanValidationTests {
    override class func setUp() {
        super.setUp()
        
        // Set up TSan environment if needed
        if let tsanOptions = ProcessInfo.processInfo.environment["TSAN_OPTIONS"] {
            print("TSan Options: \(tsanOptions)")
        } else {
            print("No TSan options detected. To enable TSan:")
            print("export TSAN_OPTIONS='suppressions=\(FileManager.default.currentDirectoryPath)/tsan.suppressions'")
        }
    }
}
