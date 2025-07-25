import XCTest
@testable import PipelineKit

/// Benchmark tests for the integer-based context storage optimization
final class ContextStorageBenchmark: PerformanceBenchmark {
    
    // Test keys for benchmarking
    struct BenchKey1: ContextKey { typealias Value = String }
    struct BenchKey2: ContextKey { typealias Value = Int }
    struct BenchKey3: ContextKey { typealias Value = Double }
    struct BenchKey4: ContextKey { typealias Value = Bool }
    struct BenchKey5: ContextKey { typealias Value = [String] }
    struct BenchKey6: ContextKey { typealias Value = Data }
    struct BenchKey7: ContextKey { typealias Value = UUID }
    struct BenchKey8: ContextKey { typealias Value = Date }
    struct BenchKey9: ContextKey { typealias Value = TimeInterval }
    struct BenchKey10: ContextKey { typealias Value = Set<String> }
    
    /// Benchmark context key access performance
    func testContextAccessPerformance() async throws {
        let context = CommandContext()
        
        // Populate context with test data
        context[BenchKey1.self] = "test string"
        context[BenchKey2.self] = 42
        context[BenchKey3.self] = 3.14159
        context[BenchKey4.self] = true
        context[BenchKey5.self] = ["a", "b", "c"]
        context[BenchKey6.self] = Data("test data".utf8)
        context[BenchKey7.self] = UUID()
        context[BenchKey8.self] = Date()
        context[BenchKey9.self] = 123.456
        context[BenchKey10.self] = Set(["x", "y", "z"])
        
        // Warm up
        for _ in 0..<100 {
            _ = context[BenchKey1.self]
            _ = context[BenchKey5.self]
            _ = context[BenchKey10.self]
        }
        
        // Benchmark read performance
        try await benchmark("Context Read Performance", iterations: 100_000) {
            // Access different keys to simulate real usage
            _ = context[BenchKey1.self]
            _ = context[BenchKey2.self]
            _ = context[BenchKey3.self]
            _ = context[BenchKey4.self]
            _ = context[BenchKey5.self]
        }
        
        // Benchmark write performance
        try await benchmark("Context Write Performance", iterations: 100_000) {
            context[BenchKey1.self] = "updated"
            context[BenchKey2.self] = 99
            context[BenchKey3.self] = 2.71828
            context[BenchKey4.self] = false
            context[BenchKey5.self] = ["x", "y"]
        }
        
        // Benchmark mixed read/write
        try await benchmark("Context Mixed Access", iterations: 100_000) {
            _ = context[BenchKey1.self]
            context[BenchKey2.self] = 100
            _ = context[BenchKey3.self]
            context[BenchKey4.self] = true
            _ = context[BenchKey5.self]
        }
    }
    
    /// Benchmark throughput for context operations
    func testContextThroughput() async throws {
        let context = CommandContext()
        
        // Pre-populate
        for i in 0..<10 {
            switch i {
            case 0: context[BenchKey1.self] = "value \(i)"
            case 1: context[BenchKey2.self] = i
            case 2: context[BenchKey3.self] = Double(i)
            case 3: context[BenchKey4.self] = i % 2 == 0
            case 4: context[BenchKey5.self] = ["item \(i)"]
            case 5: context[BenchKey6.self] = Data("data \(i)".utf8)
            case 6: context[BenchKey7.self] = UUID()
            case 7: context[BenchKey8.self] = Date()
            case 8: context[BenchKey9.self] = TimeInterval(i)
            case 9: context[BenchKey10.self] = Set(["set \(i)"])
            default: break
            }
        }
        
        // Measure operations per second
        let readThroughput = try await benchmarkThroughput("Context Read Throughput") {
            _ = context[BenchKey1.self]
            _ = context[BenchKey2.self]
            _ = context[BenchKey3.self]
        }
        
        print("Read throughput: \(Int(readThroughput)) ops/sec")
        
        let writeThroughput = try await benchmarkThroughput("Context Write Throughput") {
            context[BenchKey1.self] = "new value"
            context[BenchKey2.self] = 999
            context[BenchKey3.self] = 1.414
        }
        
        print("Write throughput: \(Int(writeThroughput)) ops/sec")
    }
    
    /// Benchmark latency for individual operations
    func testContextLatency() async throws {
        let context = CommandContext()
        
        // Pre-populate
        context[BenchKey1.self] = "test"
        context[BenchKey2.self] = 42
        context[BenchKey3.self] = 3.14
        
        // Measure read latency
        let readStats = try await benchmarkLatency("Context Read Latency", samples: 10_000) {
            _ = context[BenchKey1.self]
        }
        
        print("Read latency - p50: \(formatMicroseconds(readStats.p50)), p99: \(formatMicroseconds(readStats.p99))")
        
        // Measure write latency
        let writeStats = try await benchmarkLatency("Context Write Latency", samples: 10_000) {
            context[BenchKey1.self] = "updated"
        }
        
        print("Write latency - p50: \(formatMicroseconds(writeStats.p50)), p99: \(formatMicroseconds(writeStats.p99))")
    }
    
    /// Test key ID generation performance
    func testKeyIDGeneration() async throws {
        // First access generates ID
        let start1 = CFAbsoluteTimeGetCurrent()
        let id1 = BenchKey1.keyID
        let time1 = CFAbsoluteTimeGetCurrent() - start1
        
        // Subsequent accesses should be instant
        let start2 = CFAbsoluteTimeGetCurrent()
        let id2 = BenchKey1.keyID
        let time2 = CFAbsoluteTimeGetCurrent() - start2
        
        print("First key ID access: \(formatMicroseconds(time1))")
        print("Second key ID access: \(formatMicroseconds(time2))")
        print("Key IDs: \(id1) == \(id2)")
        
        XCTAssertEqual(id1, id2, "Key ID should be stable")
        XCTAssertLessThan(time2, time1 / 10, "Subsequent access should be much faster")
        
        // Verify different keys get different IDs
        let ids = [
            BenchKey1.keyID,
            BenchKey2.keyID,
            BenchKey3.keyID,
            BenchKey4.keyID,
            BenchKey5.keyID
        ]
        
        XCTAssertEqual(Set(ids).count, ids.count, "Each key should have unique ID")
    }
    
    /// Compare with ObjectIdentifier-based implementation (simulated)
    func testPerformanceComparison() async throws {
        let intContext = CommandContext()  // Our optimized version
        let objContext = ObjectIdentifierContext()  // Simulated old version
        
        // Populate both
        intContext[BenchKey1.self] = "test"
        objContext[BenchKey1.self] = "test"
        
        print("\n=== Performance Comparison ===")
        
        // Compare read performance
        try await comparePerformance("Context Read",
            baseline: {
                _ = objContext[BenchKey1.self]
            },
            optimized: {
                _ = intContext[BenchKey1.self]
            }
        )
        
        // Compare write performance
        try await comparePerformance("Context Write",
            baseline: {
                objContext[BenchKey1.self] = "updated"
            },
            optimized: {
                intContext[BenchKey1.self] = "updated"
            }
        )
    }
    
    // Helper to format microseconds
    private func formatMicroseconds(_ seconds: TimeInterval) -> String {
        return String(format: "%.3f μs", seconds * 1_000_000)
    }
}

// Simulated ObjectIdentifier-based context for comparison
private final class ObjectIdentifierContext {
    private var storage: [ObjectIdentifier: Any] = [:]
    private let lock = NSLock()
    
    subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage[ObjectIdentifier(key)] as? Key.Value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let value = newValue {
                storage[ObjectIdentifier(key)] = value
            } else {
                storage.removeValue(forKey: ObjectIdentifier(key))
            }
        }
    }
}