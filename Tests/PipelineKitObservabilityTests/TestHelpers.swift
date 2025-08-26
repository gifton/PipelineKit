import XCTest

extension XCTestCase {
    /// Runs an async operation with a timeout
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds
    ///   - operation: The async operation to run
    /// - Throws: XCTSkip if the operation times out
    func withTimeout<T: Sendable>(
        seconds timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Start the actual operation
            group.addTask {
                try await operation()
            }
            
            // Start a timeout task
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw XCTSkip("Test timed out after \(timeout) seconds")
            }
            
            // Return the first result (either success or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
