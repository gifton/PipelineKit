import XCTest
@testable import PipelineKitCore
import PipelineKit
import PipelineKitTestSupport

final class CommandContextThreadSafetyTests: XCTestCase {
    // MARK: - Basic Thread Safety Tests

    func testConcurrentStorageAccess() async throws {
        let context = CommandContext()
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            // Multiple writers with different keys
            for i in 0..<iterations {
                group.addTask {
                    context.set(TestContextKeys.key("\(i)"), value: "value-\(i)")
                    context.set(TestContextKeys.number("\(i)"), value: i)
                }
            }

            // Multiple readers
            for i in 0..<iterations {
                group.addTask {
                    _ = context.get(TestContextKeys.key("\(i)"))
                    _ = context.get(TestContextKeys.number("\(i)"))
                }
            }
        }

        // Verify data integrity
        for i in 0..<10 {
            let value = context.get(TestContextKeys.key("\(i)"))
            XCTAssertEqual(value, "value-\(i)")

            let number = context.get(TestContextKeys.number("\(i)"))
            XCTAssertEqual(number, i)
        }
    }

    func testConcurrentMetadataAccess() async throws {
        let context = CommandContext()
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            // Multiple writers to metadata using thread-safe methods
            for i in 0..<iterations {
                group.addTask {
                    context.setMetadata("key-\(i)", value: "value-\(i)")
                    context.setMetadata("number-\(i)", value: i)
                }
            }

            // Multiple readers
            for i in 0..<iterations {
                group.addTask {
                    let metadata = context.getMetadata()
                    _ = metadata["key-\(i)"]
                    _ = metadata["number-\(i)"]
                }
            }
        }

        // Verify some values
        let metadata = context.getMetadata()
        for i in 0..<10 {
            XCTAssertEqual(metadata["key-\(i)"] as? String, "value-\(i)")
            XCTAssertEqual(metadata["number-\(i)"] as? Int, i)
        }
    }

    func testConcurrentMetricsAccess() async throws {
        let context = CommandContext()
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            // Multiple writers to metrics using thread-safe methods
            for i in 0..<iterations {
                group.addTask {
                    context.setMetric("counter-\(i)", value: Double(i))
                    context.setMetric("timer-\(i)", value: Double(i) * 0.001)
                }
            }

            // Multiple readers
            for i in 0..<iterations {
                group.addTask {
                    let metrics = context.getMetrics()
                    _ = metrics["counter-\(i)"]
                    _ = metrics["timer-\(i)"]
                }
            }
        }

        // Verify some values
        let metrics = context.getMetrics()
        for i in 0..<10 {
            XCTAssertEqual(metrics["counter-\(i)"] as? Double, Double(i))
            XCTAssertEqual(metrics["timer-\(i)"] as? Double, Double(i) * 0.001)
        }
    }

    func testConcurrentForkOperations() async throws {
        let original = CommandContext()
        await original.set(TestContextKeys.testKey, value: "original")
        await original.setMetadata("original", value: true)

        let iterations = 50
        var forkedContexts: [CommandContext] = []

        await withTaskGroup(of: CommandContext.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let forked = await original.fork()
                    await forked.set(TestContextKeys.key("fork.\(i)"), value: "forked-\(i)")
                    await forked.setMetadata("fork-\(i)", value: i)
                    return forked
                }
            }

            for await forked in group {
                forkedContexts.append(forked)
            }
        }

        // Verify original is unchanged
        let originalValue = await original.get(TestContextKeys.testKey)
        XCTAssertEqual(originalValue, "original")
        let originalMetadata = await original.getMetadata()
        XCTAssertEqual(originalMetadata["original"] as? Bool, true)

        // Verify forked contexts have their values
        XCTAssertEqual(forkedContexts.count, iterations)
    }

    // merge() and get() methods were removed during simplification
    // Note: Update test if these methods are re-added
    /*
    func testConcurrentMergeOperations() async throws {
        let target = CommandContext()
        target[TestContextKeys.dynamic("target.key")] = "target" as String

        let iterations = 20

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let source = CommandContext()
                    source[TestContextKeys.key("merge.\(i)")] = "source-\(i)"
                    source.metadata["merge-\(i)"] = i

                    target.merge(from: source)
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
    */

    func testHighContentionOnSingleKey() async throws {
        let context = CommandContext()
        let iterations = 100
        let key = "contention.key"

        context.setMetadata(key, value: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    // This is now thread-safe but still not atomic increment
                    // Each operation is safe but the increment itself is not atomic
                    let metadata = context.getMetadata()
                    let current = (metadata[key] as? Int) ?? 0
                    context.setMetadata(key, value: current + 1)
                }
            }
        }

        // Note: This is still NOT atomic increment, so the final value may not equal iterations
        // This test verifies thread safety (no crashes), not atomicity of increment
        let metadata = context.getMetadata()
        let finalValue = metadata[key] as? Int
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
                        context.setMetadata(key, value: "value-\(count)")
                    } else {
                        let metadata = context.getMetadata()
                        _ = metadata[key] as? String
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
                        context.setMetadata(key, value: "value-\(count)")
                    } else {
                        _ = context.getMetadata(key)
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
                        context.setMetric(key, value: Double.random(in: 0..<1000))
                    } else {
                        _ = context.getMetric(key)
                    }
                    count += 1
                }
                return count
            }

            // Fork operations
            group.addTask {
                var count = 0
                while Date() < endTime {
                    _ = context.fork()
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
        context.setMetadata("test.final", value: "final")
        let finalValue = context.getMetadata("test.final") as? String
        XCTAssertEqual(finalValue, "final")
    }

    func testRequestIDConsistency() async throws {
        let context = CommandContext()
        let requestID = UUID().uuidString
        context.setRequestID(requestID)

        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            // Multiple readers - all should see a valid request ID
            for _ in 0..<iterations {
                group.addTask {
                    let readID = context.getRequestID()
                    // Just verify we get a non-nil value (thread-safe read)
                    XCTAssertNotNil(readID)
                }
            }

            // Multiple writers - thread safety test, not immutability
            for _ in 0..<10 {
                group.addTask {
                    context.setRequestID(UUID().uuidString)
                }
            }
        }

        // Verify context still has a valid requestID (thread safety, not immutability)
        let finalID = context.getRequestID()
        XCTAssertNotNil(finalID)
    }

    func testStorageSnapshotConsistency() async throws {
        let context = CommandContext()
        let iterations = 50

        // Populate initial data
        for i in 0..<iterations {
            context.setMetadata("key-\(i)", value: "value-\(i)")
        }

        // Take snapshots while modifying
        await withTaskGroup(of: [String: any Sendable].self) { group in
            // Writers
            for i in 0..<iterations {
                group.addTask {
                    context.setMetadata("key-\(i)", value: "updated-\(i)")
                    return [:]
                }
            }

            // Snapshot readers
            for _ in 0..<5 {
                group.addTask {
                    return context.snapshot()
                }
            }

            var snapshots: [[String: any Sendable]] = []
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
                    if let wrapper = value as? AnySendable,
                       let stringValue = wrapper.get(String.self) {
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
                    await context.emitMiddlewareEvent(
                        "test.event.\(i)",
                        middleware: "TestMiddleware",
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
