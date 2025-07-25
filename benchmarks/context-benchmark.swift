#!/usr/bin/env swift

import Foundation

// Simulate our optimized integer-based implementation
protocol TestContextKey {
    associatedtype Value
    static var keyID: Int { get }
}

// More efficient implementation using type metadata pointer
extension TestContextKey {
    static var keyID: Int {
        // Use the type's metadata pointer as a unique identifier
        // This is essentially free - no lookups, no allocations
        return unsafeBitCast(Self.self, to: Int.self)
    }
}

// Test keys
struct Key1: TestContextKey { typealias Value = String }
struct Key2: TestContextKey { typealias Value = Int }
struct Key3: TestContextKey { typealias Value = Double }
struct Key4: TestContextKey { typealias Value = Bool }
struct Key5: TestContextKey { typealias Value = [String] }

// Optimized context using integer keys
class OptimizedContext {
    private var storage: [Int: Any] = [:]
    private let lock = NSLock()
    
    subscript<Key: TestContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage[Key.keyID] as? Key.Value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let value = newValue {
                storage[Key.keyID] = value
            } else {
                storage.removeValue(forKey: Key.keyID)
            }
        }
    }
}

// Original context using ObjectIdentifier
class OriginalContext {
    private var storage: [ObjectIdentifier: Any] = [:]
    private let lock = NSLock()
    
    subscript<Key: TestContextKey>(_ key: Key.Type) -> Key.Value? {
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

// Benchmark function
func benchmark(_ name: String, iterations: Int, block: () -> Void) -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        block()
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    return elapsed
}

print("Context Storage Performance Benchmark")
print("=====================================\n")

// Test key ID generation
print("1. Key ID Generation")
print("-------------------")
let firstAccess = CFAbsoluteTimeGetCurrent()
let id1 = Key1.keyID
let firstTime = (CFAbsoluteTimeGetCurrent() - firstAccess) * 1_000_000

let secondAccess = CFAbsoluteTimeGetCurrent()
let id2 = Key1.keyID
let secondTime = (CFAbsoluteTimeGetCurrent() - secondAccess) * 1_000_000

print("First access: \(String(format: "%.3f", firstTime)) μs (ID: \(id1))")
print("Second access: \(String(format: "%.3f", secondTime)) μs (ID: \(id2))")
print("Speed improvement: \(String(format: "%.1fx", firstTime / secondTime))")

// Verify unique IDs
let ids = [Key1.keyID, Key2.keyID, Key3.keyID, Key4.keyID, Key5.keyID]
print("Unique IDs: \(ids)")

// Performance comparison
print("\n2. Context Access Performance")
print("-----------------------------")

let optimized = OptimizedContext()
let original = OriginalContext()

// Populate contexts
optimized[Key1.self] = "test string"
optimized[Key2.self] = 42
optimized[Key3.self] = 3.14159
optimized[Key4.self] = true
optimized[Key5.self] = ["a", "b", "c"]

original[Key1.self] = "test string"
original[Key2.self] = 42
original[Key3.self] = 3.14159
original[Key4.self] = true
original[Key5.self] = ["a", "b", "c"]

let iterations = 1_000_000

// Benchmark reads
let optimizedReadTime = benchmark("Optimized Read", iterations: iterations) {
    _ = optimized[Key1.self]
    _ = optimized[Key2.self]
    _ = optimized[Key3.self]
}

let originalReadTime = benchmark("Original Read", iterations: iterations) {
    _ = original[Key1.self]
    _ = original[Key2.self]
    _ = original[Key3.self]
}

print("\nRead Performance (3 reads × \(iterations) iterations):")
print("- Integer keys: \(String(format: "%.3f", optimizedReadTime)) seconds")
print("- ObjectIdentifier: \(String(format: "%.3f", originalReadTime)) seconds")
print("- Improvement: \(String(format: "%.1f%%", ((originalReadTime - optimizedReadTime) / originalReadTime) * 100))")
print("- Speed: \(String(format: "%.1fx", originalReadTime / optimizedReadTime)) faster")

// Benchmark writes
let optimizedWriteTime = benchmark("Optimized Write", iterations: iterations) {
    optimized[Key1.self] = "updated"
    optimized[Key2.self] = 99
    optimized[Key3.self] = 2.718
}

let originalWriteTime = benchmark("Original Write", iterations: iterations) {
    original[Key1.self] = "updated"
    original[Key2.self] = 99
    original[Key3.self] = 2.718
}

print("\nWrite Performance (3 writes × \(iterations) iterations):")
print("- Integer keys: \(String(format: "%.3f", optimizedWriteTime)) seconds")
print("- ObjectIdentifier: \(String(format: "%.3f", originalWriteTime)) seconds")
print("- Improvement: \(String(format: "%.1f%%", ((originalWriteTime - optimizedWriteTime) / originalWriteTime) * 100))")
print("- Speed: \(String(format: "%.1fx", originalWriteTime / optimizedWriteTime)) faster")

// Operations per second
let optimizedOpsPerSec = Double(iterations * 3) / optimizedReadTime
let originalOpsPerSec = Double(iterations * 3) / originalReadTime

print("\n3. Throughput")
print("-------------")
print("- Integer keys: \(String(format: "%.0f", optimizedOpsPerSec)) ops/sec")
print("- ObjectIdentifier: \(String(format: "%.0f", originalOpsPerSec)) ops/sec")

print("\n✅ Summary")
print("----------")
let readImprovement = ((originalReadTime - optimizedReadTime) / originalReadTime) * 100
let writeImprovement = ((originalWriteTime - optimizedWriteTime) / originalWriteTime) * 100
print("Integer-based keys provide approximately \(String(format: "%.0f", readImprovement))-\(String(format: "%.0f", writeImprovement))% performance improvement!")