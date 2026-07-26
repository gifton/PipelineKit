/// One progress update from an executing command.
///
/// Delivery is lossy by design: the backing stream buffer is bounded and
/// drops the oldest updates under pressure, so treat updates as hints, not a
/// complete event log.
@frozen
public struct ProgressUpdate: Sendable, Equatable {
    /// Completed fraction in `0.0...1.0` when known; `nil` for indeterminate.
    public let fraction: Double?
    public let message: String?
    public let metadata: [String: String]

    public init(fraction: Double? = nil, message: String? = nil, metadata: [String: String] = [:]) {
        self.fraction = fraction
        self.message = message
        self.metadata = metadata
    }
}

/// Capability handle for reporting progress from anywhere below the handler.
///
/// Create the pair with `makeStream`, attach the reporter to the
/// `CommandContext` via `ContextKeys.progressReporter`, and consume the
/// stream from the calling side. `StandardPipeline` and `DynamicPipeline`
/// finish the stream when execution completes or throws — including failures
/// before the middleware chain starts (type mismatch, pre-start cancellation,
/// back-pressure rejection), and for `DynamicPipeline` only after its final
/// retry attempt; other `Pipeline` conformers, such as
/// `AnyStandardPipeline`, do not bind or finish it. Reporting never blocks;
/// `report` after `finish` is a no-op (`AsyncStream.Continuation` semantics).
/// Only the execution whose `CommandContext` attached the reporter finishes
/// the stream; nested executions that attach no reporter of their own
/// inherit it for reporting but never finish it.
public struct ProgressReporter: Sendable {
    private let continuation: AsyncStream<ProgressUpdate>.Continuation

    /// - Parameter bufferSize: Maximum buffered updates when the consumer is
    ///   slow; the oldest are dropped first (`.bufferingNewest`). Must be > 0
    ///   — `.bufferingNewest(0)` would silently drop every update.
    public static func makeStream(
        bufferSize: Int = 16
    ) -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter) {
        precondition(bufferSize > 0, "ProgressReporter.makeStream bufferSize must be > 0")
        var continuation: AsyncStream<ProgressUpdate>.Continuation!
        let stream = AsyncStream<ProgressUpdate>(bufferingPolicy: .bufferingNewest(bufferSize)) {
            continuation = $0
        }
        return (stream, ProgressReporter(continuation: continuation))
    }

    public func report(
        fraction: Double? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        continuation.yield(ProgressUpdate(fraction: fraction, message: message, metadata: metadata))
    }

    /// Terminates the consumer's stream. Idempotent.
    public func finish() {
        continuation.finish()
    }
}

public extension ContextKeys {
    /// Attach point for a `ProgressReporter` so the pipeline can move it into
    /// the task-local `ExecutionContext` (see `ExecutionContext.progress`).
    static let progressReporter = ContextKey<ProgressReporter>("progressReporter")
}
