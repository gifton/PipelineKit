//
//  TestSynchronizer.swift
//  PipelineKit
//
//  Checkpoint-based synchronization utility for coordinating concurrent tests.
//

import Foundation

/// Checkpoint synchronization for concurrent tests.
public actor TestSynchronizer {
    private var checkpoints: Set<String> = []
    private var continuations: [String: [UUID: CheckedContinuation<Void, any Error>]] = [:]

    public init() {}

    /// Signal a checkpoint and resume its current waiters successfully.
    public func signal(_ checkpoint: String) {
        checkpoints.insert(checkpoint)
        if let waiting = continuations.removeValue(forKey: checkpoint) {
            for continuation in waiting.values {
                continuation.resume()
            }
        }
    }

    /// Wait for a signal, throwing `CancellationError` on cancellation or reset.
    public func waitForSignal(_ checkpoint: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if checkpoints.contains(checkpoint) { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancellation can arrive between the first check and registration.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[checkpoint, default: [:]][id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, for: checkpoint) }
        }
    }

    /// Wait for a signal, cancellation, or reset.
    /// Returning does not imply a signal; use `waitForSignal` to distinguish it.
    public func wait(for checkpoint: String) async {
        try? await waitForSignal(checkpoint)
    }

    private func cancelWaiter(_ id: UUID, for checkpoint: String) {
        let continuation = continuations[checkpoint]?.removeValue(forKey: id)
        if continuations[checkpoint]?.isEmpty == true {
            continuations.removeValue(forKey: checkpoint)
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// Clear signals and cancel all registered waiters with `CancellationError`.
    public func reset() {
        checkpoints.removeAll()
        let waiting = continuations
        continuations.removeAll()
        for checkpoint in waiting.values {
            for continuation in checkpoint.values {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Check whether a checkpoint has been signaled since the last reset.
    public func isSignaled(_ checkpoint: String) -> Bool {
        checkpoints.contains(checkpoint)
    }

    /// Registration acknowledgement for deterministic test coordination.
    internal func waiterCount(for checkpoint: String) -> Int {
        continuations[checkpoint]?.count ?? 0
    }

    public func shortDelay() async {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    public func mediumDelay() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    public func longDelay() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
