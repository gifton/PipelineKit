import Foundation
import PipelineKit
import PipelineKitCore

// MARK: - Grace Period Manager

/// Manages grace periods with cancellation support
actor GracePeriodManager {
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Starts a grace period that can be cancelled
    func startGracePeriod(
        duration: TimeInterval,
        onExpiration: @escaping @Sendable () async -> Void
    ) -> UUID {
        _ = NumericDuration.nanoseconds(duration)
        let id = UUID()

        let task = Task {
            // Gate entry: if cancelled before the sleep begins, do nothing.
            guard !Task.isCancelled else { return }

            do {
                // `Task.sleep` already throws `CancellationError` immediately on
                // cancellation, so a single sleep provides the same prompt
                // cancellation responsiveness as the previous chunked loop.
                try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(duration))
            } catch {
                // Cancelled during sleep — swallow the error and do not expire.
                return
            }

            // Grace period expired
            if !Task.isCancelled {
                await onExpiration()
            }
        }

        activeTasks[id] = task
        return id
    }

    /// Cancels a grace period
    func cancelGracePeriod(_ id: UUID) {
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks.removeValue(forKey: id)
        }
    }

    /// Cancels all active grace periods
    func cancelAll() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
    }
}

// MARK: - Timeout Context

/// Rich context for timeout errors
public struct TimeoutContext: Sendable {
    /// The command that timed out
    public let commandType: String

    /// The timeout duration that was exceeded
    public let timeoutDuration: TimeInterval

    /// How long the command actually ran before timeout
    public let actualDuration: TimeInterval

    /// Grace period configuration
    public let gracePeriod: TimeInterval

    /// Whether grace period was used
    public let gracePeriodUsed: Bool

    /// Timeout reason
    public let reason: TimeoutReason

    /// Additional metadata
    public let metadata: [String: String]

    public init(
        commandType: String,
        timeoutDuration: TimeInterval,
        actualDuration: TimeInterval,
        gracePeriod: TimeInterval,
        gracePeriodUsed: Bool,
        reason: TimeoutReason,
        metadata: [String: String] = [:]
    ) {
        self.commandType = commandType
        self.timeoutDuration = timeoutDuration
        self.actualDuration = actualDuration
        self.gracePeriod = gracePeriod
        self.gracePeriodUsed = gracePeriodUsed
        self.reason = reason
        self.metadata = metadata
    }
}
/// Reasons for timeout
public enum TimeoutReason: String, Sendable {
    case executionTimeout = "execution_timeout"
    case gracePeriodExpired = "grace_period_expired"
    case taskCancelled = "task_cancelled"
    case customTimeout = "custom_timeout"
}

// MARK: - Enhanced Timeout Error

/// Enhanced pipeline error with timeout context
public extension PipelineError {
    static func timeoutWithContext(_ context: TimeoutContext) -> PipelineError {
        let errorContext = ErrorContext(
            commandType: context.commandType,
            middlewareType: "TimeoutMiddleware",
            additionalInfo: [
                "timeout_duration": String(context.timeoutDuration),
                "actual_duration": String(context.actualDuration),
                "grace_period": String(context.gracePeriod),
                "grace_period_used": String(context.gracePeriodUsed),
                "reason": context.reason.rawValue
            ].merging(context.metadata) { _, new in new }
        )

        return .timeout(duration: context.timeoutDuration, context: errorContext)
    }
}

// MARK: - Progressive Backoff

/// A standalone calculator for progressive durations.
///
/// `TimeoutMiddleware` uses its configured fixed `gracePeriod`; it does not use
/// this calculator to select or extend its deadline.
public struct GracePeriodBackoff: Sendable {
    public let initialDuration: TimeInterval
    public let maxDuration: TimeInterval
    public let multiplier: Double
    public let jitter: Double

    public init(
        initialDuration: TimeInterval = 0.5,
        maxDuration: TimeInterval = 5.0,
        multiplier: Double = 1.5,
        jitter: Double = 0.1
    ) {
        _ = NumericDuration.nanoseconds(initialDuration)
        _ = NumericDuration.nanoseconds(maxDuration)
        precondition(multiplier.isFinite && multiplier >= 0, "Grace multiplier must be finite and nonnegative")
        precondition(jitter.isFinite && (0...1).contains(jitter), "Grace jitter must be between zero and one")
        self.initialDuration = initialDuration
        self.maxDuration = maxDuration
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// Calculate next backoff duration
    public func nextDuration(attemptNumber: Int) -> TimeInterval {
        precondition(attemptNumber >= 1, "Grace attempt must be positive")
        let baseDelay = NumericDuration.cappedProduct(initialDuration, pow(multiplier, Double(attemptNumber - 1)), maximum: maxDuration)
        let clampedDelay = min(baseDelay, maxDuration)

        // Add jitter
        let jitterRange = clampedDelay * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)

        return min(maxDuration, max(0, clampedDelay + randomJitter))
    }
}
