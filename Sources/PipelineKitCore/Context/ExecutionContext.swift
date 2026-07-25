import Foundation

/// Immutable trace identifiers for one command execution.
///
/// A frozen, `Codable` value snapshot — safe to persist (deferred execution)
/// and to read from any task. Distinct from `PipelineKitSecurity.TraceContext`,
/// which serves audit logging.
@frozen
public struct TraceMetadata: Sendable, Codable, Equatable {
    public let commandID: UUID
    public let correlationID: String?
    public let userID: String?

    public init(commandID: UUID, correlationID: String? = nil, userID: String? = nil) {
        self.commandID = commandID
        self.correlationID = correlationID
        self.userID = userID
    }
}

/// Task-local view of the current command execution, bound by the pipelines
/// around the middleware chain and handler.
///
/// Only immutable values and capability handles may be added as fields —
/// never mutable shared state (see the design doc for why the whole
/// `CommandContext` is deliberately NOT exposed this way).
///
/// `current` is `nil` outside pipeline execution and inside `Task.detached`
/// (task-locals are not inherited by detached tasks); readers must tolerate
/// `nil`.
public struct ExecutionContext: Sendable {
    public let trace: TraceMetadata
    /// Present only when the caller attached a reporter for this execution.
    public let progress: ProgressReporter?

    @TaskLocal public static var current: ExecutionContext?

    public init(trace: TraceMetadata, progress: ProgressReporter? = nil) {
        self.trace = trace
        self.progress = progress
    }
}

// MARK: - Snapshot / rebind (deferred-execution contract)

extension ExecutionContext {
    /// Codable persistence form of an `ExecutionContext`.
    ///
    /// Capability handles (`progress`) are deliberately excluded — they cannot
    /// be serialized. A deferred executor persists the snapshot at enqueue and
    /// attaches a fresh reporter at replay via `withRestored(_:progress:)`.
    @frozen
    public struct Snapshot: Sendable, Codable, Equatable {
        public let trace: TraceMetadata

        public init(trace: TraceMetadata) {
            self.trace = trace
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(trace: trace)
    }

    /// Rebinds a restored context around `operation` on the current task.
    ///
    /// This is the replay half of the deferred-execution contract: task-locals
    /// do not survive enqueue → dequeue (the work runs on a different task),
    /// so the worker re-establishes the context explicitly.
    public static func withRestored<T: Sendable>(
        _ snapshot: Snapshot,
        progress: ProgressReporter? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await ExecutionContext.$current.withValue(
            ExecutionContext(trace: snapshot.trace, progress: progress)
        ) {
            try await operation()
        }
    }
}
