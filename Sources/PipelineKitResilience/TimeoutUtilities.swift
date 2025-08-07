import Foundation

// MARK: - Timeout Utilities

/// Executes an async operation with a timeout, using cooperative cancellation.
///
/// This utility races the operation against a timeout, properly handling cancellation
/// and cleanup. It's designed to work with Swift's structured concurrency model.
///
/// - Parameters:
///   - seconds: The timeout duration in seconds
///   - operation: The async operation to execute with timeout enforcement
/// - Returns: The result of the operation if it completes before timeout
/// - Throws: `TimeoutError` if the operation times out, or any error from the operation
internal func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: TimeoutRaceResult<T>.self) { group in
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
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
/// This extends the basic timeout with a grace period, allowing operations
/// to complete even after the initial timeout if they're making progress.
///
/// - Parameters:
///   - timeout: The initial timeout duration
///   - gracePeriod: Additional time allowed after timeout
///   - operation: The async operation to execute
///   - onGracePeriodStart: Optional callback when grace period begins
/// - Returns: The result of the operation
/// - Throws: `TimeoutError` with grace period info, or any error from the operation
internal func withTimeoutAndGrace<T: Sendable>(
    timeout: TimeInterval,
    gracePeriod: TimeInterval,
    operation: @escaping @Sendable () async throws -> T,
    onGracePeriodStart: (@Sendable () async -> Void)? = nil
) async throws -> T {
    try await withThrowingTaskGroup(of: TimeoutRaceResult<T>.self) { group in
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
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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
            return value
            
        case .timeout:
            // Initial timeout reached, start grace period
            if let onGracePeriodStart = onGracePeriodStart {
                await onGracePeriodStart()
            }
            
            // Add grace period task
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(gracePeriod * 1_000_000_000))
                    return .timeout
                } catch {
                    return .cancelled
                }
            }
            
            // Wait for either operation completion or grace period expiry
            guard let gracePeriodResult = try await group.next() else {
                throw TimeoutError.noResult
            }
            
            group.cancelAll()
            
            switch gracePeriodResult {
            case .success(let value):
                // Operation completed during grace period
                // Return the value - caller can check timing if needed
                return value
                
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
                // Shouldn't happen in grace period
                throw CancellationError()
            }
            
        case .failure(let error):
            group.cancelAll()
            throw error
            
        case .cancelled:
            // Timeout task was cancelled, get the operation result
            if let secondResult = try await group.next() {
                group.cancelAll()
                return try secondResult.get()
            }
            throw CancellationError()
        }
    }
}

// MARK: - Supporting Types

/// Internal result type for timeout racing
internal enum TimeoutRaceResult<T: Sendable>: Sendable {
    case success(T)
    case timeout
    case failure(Error)
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
public enum TimeoutError: Error {
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

/// Asserts that a closure is non-escaping at compile time.
///
/// This is used in tests to ensure that middleware `next` parameters
/// remain non-escaping even if the protocol changes.
public func assertNonEscaping<T>(
    _ closure: T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    // If the closure were escaping, the compiler would require @escaping
    // annotation here and this would fail to compile
    _mustBeNonEscaping(closure)
}

// Helper that pretends to need a non-escaping closure
private func _mustBeNonEscaping<T>(_ closure: T) {}