import Foundation
import PipelineKitCore

/// Test utility for synchronizing async operations in tests
/// Provides utilities for controlled timing and sequencing of concurrent operations
public actor TestSynchronizer {
    private var checkpoints: [String: Bool] = [:]
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    
    public init() {}
    
    /// Signal that a checkpoint has been reached
    public func signal(_ checkpoint: String) {
        checkpoints[checkpoint] = true
        
        // Resume any waiting continuations
        if let waiting = continuations[checkpoint] {
            for continuation in waiting {
                continuation.resume()
            }
            continuations[checkpoint] = nil
        }
    }
    
    /// Wait for a checkpoint to be signaled
    public func wait(for checkpoint: String) async {
        // If already signaled, return immediately
        if checkpoints[checkpoint] == true {
            return
        }
        
        // Otherwise wait
        await withCheckedContinuation { continuation in
            continuations[checkpoint, default: []].append(continuation)
        }
    }
    
    /// Reset all checkpoints
    public func reset() {
        checkpoints.removeAll()
        // Cancel any waiting continuations
        for (_, continuations) in continuations {
            for continuation in continuations {
                continuation.resume()
            }
        }
        continuations.removeAll()
    }
    
    /// Check if a checkpoint has been reached
    public func isSignaled(_ checkpoint: String) -> Bool {
        checkpoints[checkpoint] ?? false
    }
    
    /// Short delay for testing
    public func shortDelay() async {
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    }
    
    /// Medium delay for testing
    public func mediumDelay() async {
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
    
    /// Long delay for testing
    public func longDelay() async {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
}
