import Foundation

// Simple benchmark runner without PipelineKit dependency
print("PipelineKit Benchmark Suite (Standalone)")
print("=======================================\n")

// Basic timing function
func measure(_ name: String, iterations: Int = 1000, block: () throws -> Void) rethrows {
    print("Running benchmark: \(name)")
    print("Iterations: \(iterations)")
    
    // Warmup
    for _ in 0..<100 {
        try block()
    }
    
    // Measure
    let start = Date()
    for _ in 0..<iterations {
        try block()
    }
    let elapsed = Date().timeIntervalSince(start)
    
    let perIteration = elapsed / Double(iterations)
    print("Results:")
    print("  Total time: \(String(format: "%.3f", elapsed))s")
    print("  Per iteration: \(formatDuration(perIteration))")
    print("  Rate: \(String(format: "%.0f", Double(iterations) / elapsed)) ops/sec")
    print()
}

func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 0.000001 {
        return String(format: "%.0f ns", seconds * 1_000_000_000)
    } else if seconds < 0.001 {
        return String(format: "%.2f µs", seconds * 1_000_000)
    } else if seconds < 1.0 {
        return String(format: "%.2f ms", seconds * 1_000)
    } else {
        return String(format: "%.2f s", seconds)
    }
}

// Run benchmarks
measure("String Operations", iterations: 10000) {
    let str = "Hello, World!"
    _ = str.uppercased().lowercased().reversed()
}

measure("Array Operations", iterations: 5000) {
    let array = Array(0..<100)
    _ = array.map { $0 * 2 }.filter { $0 > 50 }.reduce(0, +)
}

measure("Dictionary Operations", iterations: 2000) {
    var dict: [String: Int] = [:]
    for i in 0..<50 {
        dict["key-\(i)"] = i
    }
    _ = dict.values.reduce(0, +)
}

measure("Memory Allocation", iterations: 1000) {
    let size = 1024 * 10 // 10KB
    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: size,
        alignment: MemoryLayout<UInt8>.alignment
    )
    defer { buffer.deallocate() }
    memset(buffer, 0, size)
}

print("\nBenchmark suite completed!")