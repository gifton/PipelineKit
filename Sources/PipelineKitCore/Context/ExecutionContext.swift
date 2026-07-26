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

/// Task-local view of the current command execution, bound by
/// `StandardPipeline` around the middleware chain and handler, and by
/// `DynamicPipeline` around its entire retry loop (all attempts, including
/// backoff delays, observe the same context).
///
/// Only immutable values and capability handles may be added as fields —
/// never mutable shared state (see the design doc for why the whole
/// `CommandContext` is deliberately NOT exposed this way).
///
/// `current` is `nil` outside pipeline execution and inside `Task.detached`
/// (task-locals are not inherited by detached tasks); readers must tolerate
/// `nil`.
///
/// Nested executions inherit progress visibility: when a pipeline binds a
/// `CommandContext` that attaches no reporter, `progress` resolves to the
/// enclosing execution's reporter, at any nesting depth. Ownership does not
/// flow with it — only the execution whose context attached the reporter
/// finishes the stream. Trace is never inherited; each execution's
/// `TraceMetadata` comes from its own context. Prefer a fresh
/// `CommandContext` per execution: sharing one context makes the inner
/// execution the attacher, so it finishes the stream early.
public struct ExecutionContext: Sendable {
    public let trace: TraceMetadata
    /// The reporter attached by this execution's context, or inherited from
    /// the enclosing execution when none was attached; `nil` when neither
    /// exists. Only the attaching execution finishes the stream.
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
    ///
    /// `operation` runs in the caller's isolation (`#isolation` by default,
    /// mirroring `TaskLocal.withValue`), so actor-isolated callers may touch
    /// their own state inside it. The restored context never inherits an
    /// enclosing execution's reporter — `progress` is the only source.
    public static func withRestored<T>(
        _ snapshot: Snapshot,
        progress: ProgressReporter? = nil,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await ExecutionContext.$current.withValue(
            ExecutionContext(trace: snapshot.trace, progress: progress),
            operation: operation,
            isolation: isolation
        )
    }
}
