import Foundation
import PipelineKitCore

// MARK: - Timeout Utilities

/// Executes an async operation with a timeout, using cooperative cancellation.
///
/// This utility races the operation against a timeout, properly handling cancellation
/// and cleanup. It's designed to work with Swift's structured concurrency model.
///
/// - Parameters:
///   - seconds: Finite, nanosecond-representable seconds. Nonpositive values
///     throw immediately without starting the operation.
///   - operation: The async operation to execute with timeout enforcement
/// - Returns: The result of the operation if it completes before timeout
/// - Throws: `TimeoutError` if the operation times out, or any error from the operation
public func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    NumericDuration.validateTimeout(seconds)
    guard seconds > 0 else { throw TimeoutError.exceeded(duration: seconds) }
    return try await withThrowingTaskGroup(of: TimeoutRaceResult<T>.self) { group in
        // Add the main operation task
        group.addTask {
            do {
                let result = try await operation()
                return .success(result)
            } catch {
                return .failure(error)
            }
        }

        // Add the timeout task
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(max(0, seconds)))
                return .timeout
            } catch {
                // Task was cancelled (operation completed first)
                return .cancelled
            }
        }

        // Wait for the first result
        guard let firstResult = try await group.next() else {
            throw TimeoutError.noResult
        }

        // Cancel all remaining tasks (cooperative cancellation)
        group.cancelAll()

        // Handle the result
        switch firstResult {
        case .success(let value):
            return value

        case .timeout:
            throw TimeoutError.exceeded(duration: seconds)

        case .failure(let error):
            throw error

        case .cancelled:
            // This should only happen if we explicitly cancelled
            // In practice, we'll get another result from the group
            if let secondResult = try await group.next() {
                return try secondResult.get()
            }
            throw CancellationError()
        }
    }
}

/// Executes an async operation with a timeout and grace period.
///
/// This extends the basic timeout with a fixed grace period, allowing operations
/// to complete after the initial deadline. Expiry requests cancellation and waits
/// for the operation and grace notification to settle.
///
/// - Parameters:
///   - timeout: The initial timeout duration
///   - gracePeriod: Additional time allowed after timeout
///   - operation: The async operation to execute
///   - onGracePeriodStart: Optional callback when grace period begins
///   - sleep: Internal sleeper seam; production uses cancellation-aware task sleep.
/// - Returns: The operation value and whether its invocation entered grace.
/// - Throws: `TimeoutError` with grace period info, or any error from the operation
internal func withTimeoutAndGrace<T: Sendable>(
    timeout: TimeInterval,
    gracePeriod: TimeInterval,
    operation: @escaping @Sendable () async throws -> T,
    onGracePeriodStart: (@Sendable () async -> Void)? = nil,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(max(0, $0)))
    }
) async throws -> TimeoutExecutionOutcome<T> {
    NumericDuration.validateTimeout(timeout)
    _ = NumericDuration.nanoseconds(gracePeriod)
    guard timeout > 0 else { throw TimeoutError.exceeded(duration: timeout) }
    return try await withThrowingTaskGroup(of: TimeoutRaceResult<T>.self) { group in
        // Track timing
        let startTime = Date()

        // Add the main operation task
        group.addTask {
            do {
                let result = try await operation()
                return .success(result)
            } catch {
                return .failure(error)
            }
        }

        // Add the initial timeout task
        group.addTask {
            do {
                try await sleep(timeout)
                return .timeout
            } catch {
                return .cancelled
            }
        }

        // Wait for the first result
        guard let firstResult = try await group.next() else {
            throw TimeoutError.noResult
        }

        switch firstResult {
        case .success(let value):
            // Operation completed within timeout
            group.cancelAll()
            return TimeoutExecutionOutcome(value: value, gracePeriodUsed: false)

        case .timeout:
            // Register the deadline independently of the diagnostic callback.
            group.addTask {
                do {
                    try await sleep(gracePeriod)
                    return .timeout
                } catch {
                    return .cancelled
                }
            }

            // Scope exit cancels and joins this child. Ownership is exercised by
            // testSuspendedGraceEventDoesNotDelayCancellationAndRemainsOwned.
            async let _: Void? = onGracePeriodStart?()

            // Wait for either operation completion or grace period expiry
            guard let gracePeriodResult = try await group.next() else {
                throw TimeoutError.noResult
            }

            group.cancelAll()

            switch gracePeriodResult {
            case .success(let value):
                return TimeoutExecutionOutcome(value: value, gracePeriodUsed: true)

            case .timeout:
                // Grace period also expired
                let totalDuration = Date().timeIntervalSince(startTime)
                throw TimeoutError.gracePeriodExpired(
                    timeout: timeout,
                    gracePeriod: gracePeriod,
                    totalDuration: totalDuration
                )

            case .failure(let error):
                throw error

            case .cancelled:
                // Timer cancellation is not an operation result. The remaining
                // group child owns the handler's success or original error.
                if let operationResult = try await group.next() {
                    return TimeoutExecutionOutcome(value: try operationResult.get(), gracePeriodUsed: true)
                }
                throw CancellationError()
            }

        case .failure(let error):
            group.cancelAll()
            throw error

        case .cancelled:
            // Timeout task was cancelled, get the operation result
            if let secondResult = try await group.next() {
                group.cancelAll()
                return TimeoutExecutionOutcome(value: try secondResult.get(), gracePeriodUsed: false)
            }
            throw CancellationError()
        }
    }
}

// MARK: - Supporting Types

/// The outcome selected by one timeout invocation's task-group control flow.
internal struct TimeoutExecutionOutcome<T: Sendable>: Sendable {
    let value: T
    let gracePeriodUsed: Bool
}

/// Internal result type for timeout racing
internal enum TimeoutRaceResult<T: Sendable>: Sendable {
    case success(T)
    case timeout
    case failure(any Error)
    case cancelled

    func get() throws -> T {
        switch self {
        case .success(let value):
            return value
        case .timeout:
            throw TimeoutError.exceeded(duration: 0)
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

/// Detailed timeout error information
public enum TimeoutError: Error, Sendable {
    /// Operation exceeded the specified timeout
    case exceeded(duration: TimeInterval)

    /// Grace period expired without completion
    case gracePeriodExpired(
        timeout: TimeInterval,
        gracePeriod: TimeInterval,
        totalDuration: TimeInterval
    )

    /// No result from task group (shouldn't happen)
    case noResult
}

/// Result wrapper for grace period completion
public struct GracePeriodCompletion<T: Sendable>: Sendable {
    public let result: T
    public let duration: TimeInterval
    public let timeout: TimeInterval
    public let gracePeriod: TimeInterval
}

// MARK: - Testing Support

/// Legacy no-op compatibility helper.
///
/// Its generic value parameter does not enforce closure escaping semantics.
public func assertNonEscaping<T>(
    _ closure: T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    _ = closure
}
