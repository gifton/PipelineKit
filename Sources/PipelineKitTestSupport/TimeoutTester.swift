import Foundation
@testable import PipelineKit

/// Test utility for validating timeout behavior
/// Provides controlled timeout scenarios for testing
public final class TimeoutTester: @unchecked Sendable {
    public init() {}
    
    /// Simulate an operation that will timeout
    public func operationThatWillTimeout(after timeout: TimeInterval) async throws {
        // Sleep for longer than the timeout
        try await Task.sleep(nanoseconds: UInt64((timeout + 1.0) * 1_000_000_000))
    }
    
    /// Simulate an operation that completes just before timeout
    public func operationThatCompletesJustInTime(before timeout: TimeInterval) async throws {
        // Sleep for slightly less than the timeout
        try await Task.sleep(nanoseconds: UInt64((timeout * 0.8) * 1_000_000_000))
    }
    
    /// Simulate an operation with configurable delay
    public func operation(withDelay delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    
    /// Run an operation with a timeout
    public func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PipelineError.cancelled(context: "Timeout after \(timeout)s")
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    /// Test if an operation times out
    public func expectTimeout<T: Sendable>(
        within timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async -> Bool {
        do {
            _ = try await withTimeout(timeout, operation: operation)
            return false // Did not timeout
        } catch let error as PipelineError {
            if case .cancelled = error {
                return true // Did timeout as expected
            }
            return false // Different error
        } catch {
            return false // Other error
        }
    }
    
    /// Run with a simulated timeout (just sleeps for the duration)
    public func runWithTimeout(_ timeout: TimeInterval, operation: () async throws -> Void = {}) async throws {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        try await operation()
    }
}
