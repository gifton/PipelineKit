import Foundation

/// Benchmark to test the framework itself
struct FrameworkOverheadBenchmark: Benchmark {
    let name = "Benchmark Framework Overhead"
    let iterations = 10000
    let warmupIterations = 1000
    
    func run() async throws {
        // Empty - measures pure framework overhead
    }
}

/// Benchmark for memory allocation patterns
struct MemoryAllocationBenchmark: Benchmark {
    let name = "Memory Allocation Patterns"
    let iterations = 1000
    let warmupIterations = 100
    
    func run() async throws {
        // Allocate and deallocate memory
        let size = 1024 * 10 // 10KB
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        
        // Touch memory to ensure allocation
        memset(buffer, 42, size)
    }
}

/// Benchmark for string operations
struct StringOperationsBenchmark: Benchmark {
    let name = "String Operations"
    let iterations = 5000
    let warmupIterations = 500
    
    func run() async throws {
        let base = "Hello, World!"
        var result = base
        
        for i in 0..<10 {
            result = result.uppercased()
            result = result.lowercased()
            result = result.replacingOccurrences(of: "o", with: "\(i)")
            result = String(result.reversed())
        }
        
        _ = result
    }
}

/// Benchmark for dictionary operations
struct DictionaryOperationsBenchmark: Benchmark {
    let name = "Dictionary Operations"
    let iterations = 2000
    let warmupIterations = 200
    
    func run() async throws {
        var dict: [String: Int] = [:]
        
        // Insert
        for i in 0..<100 {
            dict["key-\(i)"] = i
        }
        
        // Update
        for i in 0..<100 {
            dict["key-\(i)"] = i * 2
        }
        
        // Lookup
        var sum = 0
        for i in 0..<100 {
            sum += dict["key-\(i)"] ?? 0
        }
        
        // Delete
        for i in 0..<50 {
            dict.removeValue(forKey: "key-\(i)")
        }
        
        _ = sum
    }
}

/// Benchmark for concurrent dictionary access
struct ConcurrentDictionaryBenchmark: Benchmark {
    let name = "Concurrent Dictionary Access"
    let iterations = 500
    let warmupIterations = 50
    
    actor SafeDictionary {
        private var storage: [String: Int] = [:]
        
        func set(_ value: Int, for key: String) {
            storage[key] = value
        }
        
        func get(_ key: String) -> Int? {
            storage[key]
        }
    }
    
    func run() async throws {
        let dict = SafeDictionary()
        
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<5 {
                group.addTask {
                    for j in 0..<20 {
                        await dict.set(i * j, for: "key-\(i)-\(j)")
                    }
                }
            }
            
            // Readers
            for i in 0..<5 {
                group.addTask {
                    for j in 0..<20 {
                        _ = await dict.get("key-\(i)-\(j)")
                    }
                }
            }
        }
    }
}

/// Simple benchmark suite
public struct SimpleBenchmarkSuite {
    public static func all() -> [any Benchmark] {
        [
            FrameworkOverheadBenchmark(),
            MemoryAllocationBenchmark(),
            StringOperationsBenchmark(),
            DictionaryOperationsBenchmark(),
            ConcurrentDictionaryBenchmark()
        ]
    }
}