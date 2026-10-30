import Foundation
import Synchronization

/// A synchronous clock read and cancellation-aware sleeper for admission tests.
/// All mutable state is accessed under `state`; callbacks resume outside that lock.
final class ManualAdmissionClock: Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var instant: Duration = .zero
        var sleepers: [UUID: Sleeper] = [:]
        var calls = 0
        var completed = 0
        var onNextRead: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    func now() -> Duration {
        let (instant, callback) = state.withLock { state in
            let callback = state.onNextRead
            state.onNextRead = nil
            return (state.instant, callback)
        }
        callback?()
        return instant
    }

    /// Runs once, synchronously during the gate's next time read.
    func onNextRead(_ callback: @escaping @Sendable () -> Void) {
        state.withLock { $0.onNextRead = callback }
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        let ready = state.withLock { state in
            state.instant += duration
            let ids = state.sleepers.compactMap { id, sleeper in
                sleeper.deadline <= state.instant ? id : nil
            }
            return ids.compactMap { state.sleepers.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready { continuation.resume() }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        state.withLock { $0.calls += 1 }
        defer { state.withLock { $0.completed += 1 } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    state.sleepers[id] = Sleeper(
                        deadline: state.instant + duration,
                        continuation: continuation
                    )
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = self.state.withLock { $0.sleepers.removeValue(forKey: id)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }

    var sleepingCount: Int { state.withLock { $0.sleepers.count } }
    var callCount: Int { state.withLock { $0.calls } }
    var completedCount: Int { state.withLock { $0.completed } }

    func waitForSleepers(_ count: Int) async {
        while sleepingCount != count { await Task.yield() }
    }

    func waitForSettlement() async {
        while state.withLock({ $0.completed != $0.calls }) { await Task.yield() }
    }
}
