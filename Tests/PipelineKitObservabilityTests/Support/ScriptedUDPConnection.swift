import Foundation
import Synchronization
@testable import PipelineKitObservability

/// Deliberately permits late/duplicate callbacks and sends with no callback.
final class ScriptedUDPConnection: UDPConnectionDriver, Sendable {
    struct Snapshot: Sendable {
        var starts = 0
        var sends = 0
        var cancels = 0
        var stateCallbacks = 0
        var sendCallbacks = 0
    }

    private struct State {
        var snapshot = Snapshot()
        var onState: (@Sendable (UDPConnectionState) -> Void)?
        var completions: [@Sendable (Result<Void, TransportError>) -> Void] = []
        var payloads: [Data] = []
    }

    private let state = Mutex(State())

    func start(onState: @escaping @Sendable (UDPConnectionState) -> Void) {
        state.withLock {
            $0.snapshot.starts += 1
            $0.onState = onState
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void) {
        state.withLock {
            $0.snapshot.sends += 1
            $0.payloads.append(data)
            $0.completions.append(completion)
        }
    }

    func cancel() {
        state.withLock { $0.snapshot.cancels += 1 }
    }

    func emit(_ event: UDPConnectionState) {
        let callback = state.withLock { state in
            state.snapshot.stateCallbacks += 1
            return state.onState
        }
        precondition(callback != nil, "Await startup registration before emitting")
        callback?(event)
    }

    func completeSend(_ index: Int, with result: Result<Void, TransportError>) {
        let callback = state.withLock { state in
            state.snapshot.sendCallbacks += 1
            return state.completions[index]
        }
        callback(result)
    }

    var snapshot: Snapshot { state.withLock { $0.snapshot } }
    var payloads: [Data] { state.withLock { $0.payloads } }

    func waitForStarts(_ count: Int) async {
        while snapshot.starts < count { await Task.yield() }
    }

    func waitForSends(_ count: Int) async {
        while snapshot.sends < count { await Task.yield() }
    }
}

/// Each suspension is acknowledged; cancellation removes it synchronously.
final class ManualUDPSleeper: Sendable {
    struct Snapshot: Sendable {
        var entered = 0
        var returned = 0
        var pending = 0
    }

    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var entered = 0
        var returned = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        state.withLock { $0.entered += 1 }
        defer { state.withLock { $0.returned += 1 } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        state.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                    }
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advanceFirst() {
        let waiter = state.withLock { $0.waiters.removeFirst() }
        waiter.continuation.resume()
    }

    var durations: [Duration] { state.withLock { $0.waiters.map(\.duration) } }
    var snapshot: Snapshot {
        state.withLock { Snapshot(entered: $0.entered, returned: $0.returned, pending: $0.waiters.count) }
    }

    func waitForPending(_ count: Int) async {
        while snapshot.pending != count { await Task.yield() }
    }

    func join() async {
        while true {
            let current = snapshot
            if current.pending == 0 && current.entered == current.returned { return }
            await Task.yield()
        }
    }
}

actor UDPEntryGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        while continuation == nil { await Task.yield() }
    }

    func release() {
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }
}

actor UDPSettlementLedger {
    private(set) var values: [String] = []

    func record(_ operation: @Sendable () async throws -> Void) async -> String {
        let value: String
        do {
            try await operation()
            value = "success"
        } catch is CancellationError {
            value = "cancelled"
        } catch let error as TransportError {
            switch error {
            case .connectionFailed(let message): value = "connection:\(message)"
            case .sendFailed(let message): value = "send:\(message)"
            case .timeout: value = "timeout"
            case .invalidConfiguration: value = "invalid"
            case .transportClosed: value = "closed"
            }
        } catch {
            value = "unexpected:\(error)"
        }
        values.append(value)
        return value
    }
}
