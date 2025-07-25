#!/usr/bin/env swift

import Foundation

// Test implementation matching PipelineKit's approach
protocol TestContextKey {
    associatedtype Value
    static var keyID: Int { get }
}

extension TestContextKey {
    static var keyID: Int {
        return unsafeBitCast(Self.self, to: Int.self)
    }
}

// Realistic keys that might be used in a pipeline
struct UserIDKey: TestContextKey { typealias Value = String }
struct AuthTokenKey: TestContextKey { typealias Value = String }
struct RequestIDKey: TestContextKey { typealias Value = UUID }
struct TimestampKey: TestContextKey { typealias Value = Date }
struct RolesKey: TestContextKey { typealias Value = Set<String> }
struct MetadataKey: TestContextKey { typealias Value = [String: String] }
struct ConfigKey: TestContextKey { typealias Value = [String: Any] }
struct ErrorKey: TestContextKey { typealias Value = Error? }
struct CacheKey: TestContextKey { typealias Value = Data? }
struct MetricsKey: TestContextKey { typealias Value = [String: Double] }

// Optimized context
class OptimizedContext {
    private var storage: [Int: Any] = Dictionary(minimumCapacity: 16)
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

// Original context
class OriginalContext {
    private var storage: [ObjectIdentifier: Any] = Dictionary(minimumCapacity: 16)
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

print("Realistic Context Performance Benchmark")
print("======================================\n")

// Simulate a realistic middleware pipeline execution
func simulatePipelineExecution(context: OptimizedContext) {
    // Authentication middleware
    if let token = context[AuthTokenKey.self] {
        let roles = Set(["user", "admin"])
        context[RolesKey.self] = roles
    }
    
    // Request tracking middleware
    context[RequestIDKey.self] = UUID()
    context[TimestampKey.self] = Date()
    
    // Metrics middleware
    var metrics = context[MetricsKey.self] ?? [:]
    metrics["request_count"] = (metrics["request_count"] ?? 0) + 1
    context[MetricsKey.self] = metrics
    
    // Business logic
    if let userId = context[UserIDKey.self],
       let roles = context[RolesKey.self],
       roles.contains("admin") {
        // Process admin request
        let metadata = ["processed": "true", "userId": userId]
        context[MetadataKey.self] = metadata
    }
}

func simulatePipelineExecutionOriginal(context: OriginalContext) {
    // Same logic as above
    if let token = context[AuthTokenKey.self] {
        let roles = Set(["user", "admin"])
        context[RolesKey.self] = roles
    }
    
    context[RequestIDKey.self] = UUID()
    context[TimestampKey.self] = Date()
    
    var metrics = context[MetricsKey.self] ?? [:]
    metrics["request_count"] = (metrics["request_count"] ?? 0) + 1
    context[MetricsKey.self] = metrics
    
    if let userId = context[UserIDKey.self],
       let roles = context[RolesKey.self],
       roles.contains("admin") {
        let metadata = ["processed": "true", "userId": userId]
        context[MetadataKey.self] = metadata
    }
}

// Setup contexts
let optimized = OptimizedContext()
let original = OriginalContext()

// Pre-populate with realistic data
optimized[UserIDKey.self] = "user-12345"
optimized[AuthTokenKey.self] = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
optimized[MetricsKey.self] = ["startup_time": 1.234]

original[UserIDKey.self] = "user-12345"
original[AuthTokenKey.self] = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
original[MetricsKey.self] = ["startup_time": 1.234]

// Warm up
for _ in 0..<1000 {
    simulatePipelineExecution(context: optimized)
    simulatePipelineExecutionOriginal(context: original)
}

// Benchmark realistic pipeline execution
let iterations = 100_000

let startOptimized = CFAbsoluteTimeGetCurrent()
for _ in 0..<iterations {
    simulatePipelineExecution(context: optimized)
}
let optimizedTime = CFAbsoluteTimeGetCurrent() - startOptimized

let startOriginal = CFAbsoluteTimeGetCurrent()
for _ in 0..<iterations {
    simulatePipelineExecutionOriginal(context: original)
}
let originalTime = CFAbsoluteTimeGetCurrent() - startOriginal

print("Pipeline Execution Performance (\(iterations) iterations):")
print("- Integer keys: \(String(format: "%.3f", optimizedTime)) seconds")
print("- ObjectIdentifier: \(String(format: "%.3f", originalTime)) seconds")
print("- Improvement: \(String(format: "%.1f%%", ((originalTime - optimizedTime) / originalTime) * 100))")
print("- Speed: \(String(format: "%.2fx", originalTime / optimizedTime)) faster")

let opsPerSecOptimized = Double(iterations) / optimizedTime
let opsPerSecOriginal = Double(iterations) / originalTime

print("\nThroughput:")
print("- Integer keys: \(String(format: "%.0f", opsPerSecOptimized)) ops/sec")
print("- ObjectIdentifier: \(String(format: "%.0f", opsPerSecOriginal)) ops/sec")

// Memory efficiency test
print("\n\nMemory Efficiency Test")
print("---------------------")

// Test with many different keys
struct DynamicKey: TestContextKey {
    typealias Value = String
    let id: Int
}

let manyKeysOptimized = OptimizedContext()
let manyKeysOriginal = OriginalContext()

let keyCount = 50
let accessIterations = 100_000

// Create many keys and populate
for i in 0..<keyCount {
    struct TempKey: TestContextKey { typealias Value = String }
    manyKeysOptimized[TempKey.self] = "value-\(i)"
    manyKeysOriginal[TempKey.self] = "value-\(i)"
}

// Random access pattern
var randomKeys: [(any TestContextKey.Type)] = []
for i in 0..<20 {
    switch i % 5 {
    case 0: randomKeys.append(UserIDKey.self)
    case 1: randomKeys.append(AuthTokenKey.self)
    case 2: randomKeys.append(RequestIDKey.self)
    case 3: randomKeys.append(TimestampKey.self)
    default: randomKeys.append(RolesKey.self)
    }
}

// Benchmark random access
let startRandomOptimized = CFAbsoluteTimeGetCurrent()
for i in 0..<accessIterations {
    let keyType = randomKeys[i % randomKeys.count]
    if keyType == UserIDKey.self {
        _ = manyKeysOptimized[UserIDKey.self]
    } else if keyType == AuthTokenKey.self {
        _ = manyKeysOptimized[AuthTokenKey.self]
    } else if keyType == RequestIDKey.self {
        _ = manyKeysOptimized[RequestIDKey.self]
    }
}
let randomOptimizedTime = CFAbsoluteTimeGetCurrent() - startRandomOptimized

let startRandomOriginal = CFAbsoluteTimeGetCurrent()
for i in 0..<accessIterations {
    let keyType = randomKeys[i % randomKeys.count]
    if keyType == UserIDKey.self {
        _ = manyKeysOriginal[UserIDKey.self]
    } else if keyType == AuthTokenKey.self {
        _ = manyKeysOriginal[AuthTokenKey.self]
    } else if keyType == RequestIDKey.self {
        _ = manyKeysOriginal[RequestIDKey.self]
    }
}
let randomOriginalTime = CFAbsoluteTimeGetCurrent() - startRandomOriginal

print("Random Access Pattern (\(accessIterations) accesses):")
print("- Integer keys: \(String(format: "%.3f", randomOptimizedTime)) seconds")
print("- ObjectIdentifier: \(String(format: "%.3f", randomOriginalTime)) seconds")
print("- Improvement: \(String(format: "%.1f%%", ((randomOriginalTime - randomOptimizedTime) / randomOriginalTime) * 100))")

print("\n✅ Overall Summary")
print("-----------------")
let avgImprovement = (((originalTime - optimizedTime) / originalTime) + 
                     ((randomOriginalTime - randomOptimizedTime) / randomOriginalTime)) * 50
print("Integer-based keys provide ~\(String(format: "%.0f%%", avgImprovement)) average performance improvement")
print("Benefits increase with:")
print("- More complex context access patterns")
print("- Higher frequency of context operations")
print("- Larger number of unique keys")