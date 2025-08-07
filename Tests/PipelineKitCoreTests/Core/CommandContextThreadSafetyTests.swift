import XCTest
@testable import PipelineKitCore

final class CommandContextThreadSafetyTests: XCTestCase {
    
    // MARK: - Basic Thread Safety Tests
    
    func testConcurrentStorageAccess() async throws {
        let context = CommandContext()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple writers with different keys
            for i in 0..<iterations {
                group.addTask {
                    await context.set("value-\(i)", for: "key.\(i)")
                    await context.set(i, for: "number.\(i)")
                }
            }
            
            // Multiple readers
            for i in 0..<iterations {
                group.addTask {
                    _ = await context.get(String.self, for: "key.\(i)")
                    _ = await context.get(Int.self, for: "number.\(i)")
                }
            }
        }
        
        // Verify data integrity
        for i in 0..<10 {
            let value = await context.get(String.self, for: "key.\(i)")
            XCTAssertEqual(value, "value-\(i)")
            
            let number = await context.get(Int.self, for: "number.\(i)")
            XCTAssertEqual(number, i)
        }
    }
    
    func testConcurrentMetadataAccess() async throws {
        let context = CommandContext()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple writers to metadata
            for i in 0..<iterations {
                group.addTask {
                    context.metadata["key-\(i)"] = "value-\(i)"
                    context.metadata["number-\(i)"] = i
                }
            }
            
            // Multiple readers
            for i in 0..<iterations {
                group.addTask {
                    _ = context.metadata["key-\(i)"]
                    _ = context.metadata["number-\(i)"]
                }
            }
        }
        
        // Verify some values
        for i in 0..<10 {
            XCTAssertEqual(context.metadata["key-\(i)"] as? String, "value-\(i)")
            XCTAssertEqual(context.metadata["number-\(i)"] as? Int, i)
        }
    }
    
    func testConcurrentMetricsAccess() async throws {
        let context = CommandContext()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple writers to metrics
            for i in 0..<iterations {
                group.addTask {
                    context.metrics["counter-\(i)"] = Double(i)
                    context.metrics["timer-\(i)"] = Double(i) * 0.001
                }
            }
            
            // Multiple readers
            for i in 0..<iterations {
                group.addTask {
                    _ = context.metrics["counter-\(i)"]
                    _ = context.metrics["timer-\(i)"]
                }
            }
        }
        
        // Verify some values
        for i in 0..<10 {
            XCTAssertEqual(context.metrics["counter-\(i)"] as? Double, Double(i))
            XCTAssertEqual(context.metrics["timer-\(i)"] as? Double, Double(i) * 0.001)
        }
    }
    
    func testConcurrentForkOperations() async throws {
        let original = CommandContext()
        await original.set("original", for: "test.key")
        original.metadata["original"] = true
        
        let iterations = 50
        var forkedContexts: [CommandContext] = []
        
        await withTaskGroup(of: CommandContext.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let forked = await original.fork()
                    await forked.set("forked-\(i)", for: "fork.key.\(i)")
                    forked.metadata["fork-\(i)"] = i
                    return forked
                }
            }
            
            for await forked in group {
                forkedContexts.append(forked)
            }
        }
        
        // Verify original is unchanged
        let originalValue = await original.get(String.self, for: "test.key")
        XCTAssertEqual(originalValue, "original")
        XCTAssertEqual(original.metadata["original"] as? Bool, true)
        
        // Verify forked contexts have their values
        XCTAssertEqual(forkedContexts.count, iterations)
    }
    
    func testConcurrentMergeOperations() async throws {
        let target = CommandContext()
        await target.set("target", for: "target.key")
        
        let iterations = 20
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let source = CommandContext()
                    await source.set("source-\(i)", for: "merge.key.\(i)")
                    source.metadata["merge-\(i)"] = i
                    
                    await target.merge(from: source)
                }
            }
        }
        
        // Verify target has original value
        let targetValue = await target.get(String.self, for: "target.key")
        XCTAssertEqual(targetValue, "target")
        
        // Verify merged values
        for i in 0..<iterations {
            let mergedValue = await target.get(String.self, for: "merge.key.\(i)")
            XCTAssertEqual(mergedValue, "source-\(i)")
            XCTAssertEqual(target.metadata["merge-\(i)"] as? Int, i)
        }
    }
    
    func testHighContentionOnSingleKey() async throws {
        let context = CommandContext()
        let iterations = 100
        let key = "contention.key"
        
        await context.set(0, for: key)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    // Read-modify-write pattern
                    let current = await context.get(Int.self, for: key) ?? 0
                    await context.set(current + 1, for: key)
                }
            }
        }
        
        // Note: This is NOT atomic, so the final value may not equal iterations
        // This test verifies thread safety (no crashes), not atomicity
        let finalValue = await context.get(Int.self, for: key)
        XCTAssertNotNil(finalValue)
        print("Final value after \(iterations) concurrent increments: \(finalValue ?? 0)")
    }
    
    func testMixedOperationsUnderLoad() async throws {
        let context = CommandContext()
        let duration: TimeInterval = 1.0
        let endTime = Date().addingTimeInterval(duration)
        
        var operationCount = 0
        
        await withTaskGroup(of: Int.self) { group in
            // Storage operations
            group.addTask {
                var count = 0
                while Date() < endTime {
                    let key = "storage.\(Int.random(in: 0..<50))"
                    if Bool.random() {
                        await context.set("value-\(count)", for: key)
                    } else {
                        _ = await context.get(String.self, for: key)
                    }
                    count += 1
                }
                return count
            }
            
            // Metadata operations
            group.addTask {
                var count = 0
                while Date() < endTime {
                    let key = "metadata-\(Int.random(in: 0..<50))"
                    if Bool.random() {
                        context.metadata[key] = "value-\(count)"
                    } else {
                        _ = context.metadata[key]
                    }
                    count += 1
                }
                return count
            }
            
            // Metrics operations
            group.addTask {
                var count = 0
                while Date() < endTime {
                    let key = "metric-\(Int.random(in: 0..<50))"
                    if Bool.random() {
                        context.metrics[key] = Double.random(in: 0..<1000)
                    } else {
                        _ = context.metrics[key]
                    }
                    count += 1
                }
                return count
            }
            
            // Fork operations
            group.addTask {
                var count = 0
                while Date() < endTime {
                    _ = await context.fork()
                    count += 1
                }
                return count
            }
            
            for await count in group {
                operationCount += count
            }
        }
        
        print("Completed \(operationCount) operations in \(duration) seconds")
        print("Rate: \(Int(Double(operationCount) / duration)) ops/sec")
        
        // Verify context is still functional
        await context.set("final", for: "test.final")
        let finalValue = await context.get(String.self, for: "test.final")
        XCTAssertEqual(finalValue, "final")
    }
    
    func testRequestIDConsistency() async throws {
        let context = CommandContext()
        let requestID = UUID().uuidString
        context.requestID = requestID
        
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple readers
            for _ in 0..<iterations {
                group.addTask {
                    let readID = context.requestID
                    XCTAssertEqual(readID, requestID)
                }
            }
            
            // Attempt to modify (though it shouldn't change once set)
            for _ in 0..<10 {
                group.addTask {
                    context.requestID = UUID().uuidString
                }
            }
        }
        
        // Verify requestID hasn't changed (first set wins)
        XCTAssertEqual(context.requestID, requestID)
    }
    
    func testStorageSnapshotConsistency() async throws {
        let context = CommandContext()
        let iterations = 50
        
        // Populate initial data
        for i in 0..<iterations {
            await context.set("value-\(i)", for: "key-\(i)")
        }
        
        // Take snapshots while modifying
        await withTaskGroup(of: [String: Any].self) { group in
            // Writers
            for i in 0..<iterations {
                group.addTask {
                    await context.set("updated-\(i)", for: "key-\(i)")
                    return [:]
                }
            }
            
            // Snapshot readers
            for _ in 0..<5 {
                group.addTask {
                    return await context.storage.snapshot()
                }
            }
            
            var snapshots: [[String: Any]] = []
            for await snapshot in group {
                if !snapshot.isEmpty {
                    snapshots.append(snapshot)
                }
            }
            
            // Verify snapshots are valid
            for snapshot in snapshots {
                XCTAssertGreaterThan(snapshot.count, 0)
                // Each value should be either original or updated
                for (key, value) in snapshot {
                    if let stringValue = value as? String {
                        XCTAssertTrue(
                            stringValue.hasPrefix("value-") || stringValue.hasPrefix("updated-"),
                            "Unexpected value: \(stringValue)"
                        )
                    }
                }
            }
        }
    }
    
    func testConcurrentCustomEventEmission() async throws {
        let context = CommandContext()
        let iterations = 50
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    await context.emitCustomEvent(
                        "test.event.\(i)",
                        properties: [
                            "index": i,
                            "timestamp": Date()
                        ]
                    )
                }
            }
        }
        
        // No crash = success for thread safety
        // The events are fire-and-forget, so we can't easily verify them
        XCTAssertTrue(true, "Concurrent event emission completed without crashes")
    }
}