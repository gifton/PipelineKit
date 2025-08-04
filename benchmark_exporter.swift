#!/usr/bin/env swift

import Foundation

// Simple benchmark to test ExporterWrapper performance
// This creates a minimal version to establish baseline performance

final class BenchmarkLock {
    private let lock = NSLock()
    private var value: Int = 0
    
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
    
    func getValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

actor BenchmarkActor {
    private var value: Int = 0
    
    func increment() -> Int {
        value += 1
        return value
    }
    
    func getValue() -> Int {
        return value
    }
}

// Benchmark NSLock performance
func benchmarkNSLock(operations: Int, concurrent: Bool) async -> Double {
    let lock = BenchmarkLock()
    let start = ProcessInfo.processInfo.systemUptime
    
    if concurrent {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<operations {
                group.addTask {
                    _ = lock.increment()
                }
            }
        }
    } else {
        for _ in 0..<operations {
            _ = lock.increment()
        }
    }
    
    let end = ProcessInfo.processInfo.systemUptime
    return end - start
}

// Benchmark Actor performance
func benchmarkActor(operations: Int, concurrent: Bool) async -> Double {
    let actor = BenchmarkActor()
    let start = ProcessInfo.processInfo.systemUptime
    
    if concurrent {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<operations {
                group.addTask {
                    _ = await actor.increment()
                }
            }
        }
    } else {
        for _ in 0..<operations {
            _ = await actor.increment()
        }
    }
    
    let end = ProcessInfo.processInfo.systemUptime
    return end - start
}

// Run benchmarks
print("ExporterWrapper Performance Benchmark")
print("=====================================")

let operations = 100_000

// Sequential operations
let lockSeqTime = await benchmarkNSLock(operations: operations, concurrent: false)
let actorSeqTime = await benchmarkActor(operations: operations, concurrent: false)

print("\nSequential Operations (\(operations) ops):")
print("NSLock:  \(String(format: "%.4f", lockSeqTime))s (\(String(format: "%.0f", Double(operations)/lockSeqTime)) ops/sec)")
print("Actor:   \(String(format: "%.4f", actorSeqTime))s (\(String(format: "%.0f", Double(operations)/actorSeqTime)) ops/sec)")
print("Overhead: \(String(format: "%.1f", ((actorSeqTime/lockSeqTime) - 1) * 100))%")

// Concurrent operations
let lockConcTime = await benchmarkNSLock(operations: operations, concurrent: true)
let actorConcTime = await benchmarkActor(operations: operations, concurrent: true)

print("\nConcurrent Operations (\(operations) ops):")
print("NSLock:  \(String(format: "%.4f", lockConcTime))s (\(String(format: "%.0f", Double(operations)/lockConcTime)) ops/sec)")
print("Actor:   \(String(format: "%.4f", actorConcTime))s (\(String(format: "%.0f", Double(operations)/actorConcTime)) ops/sec)")
print("Overhead: \(String(format: "%.1f", ((actorConcTime/lockConcTime) - 1) * 100))%")