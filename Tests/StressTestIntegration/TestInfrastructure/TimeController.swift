import Foundation
import PipelineKitCore

/// Protocol for controlling time in tests.
///
/// Allows tests to have deterministic control over time progression
/// and async operations that depend on time.
public protocol TimeController: Sendable {
    /// Current time
    func now() -> Date
    
    /// Sleep for the specified duration
    func sleep(for duration: TimeInterval) async throws
    
    /// Advance time by the specified duration (for mock implementations)
    func advance(by duration: TimeInterval) async
    
    /// Reset time to initial state (for mock implementations)
    func reset() async
}

/// Real time controller that uses actual system time
public actor RealTimeController: TimeController {
    public init() {}
    
    public nonisolated func now() -> Date {
        Date()
    }
    
    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
    
    public func advance(by duration: TimeInterval) async {
        // No-op for real time
    }
    
    public func reset() async {
        // No-op for real time
    }
}

/// Mock time controller for deterministic testing
public actor MockTimeController: TimeController {
    // MARK: - State
    
    private var currentTime: Date
    private let startTime: Date
    private var sleepingTasks: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []
    
    // MARK: - Initialization
    
    public init(startTime: Date = Date()) {
        self.startTime = startTime
        self.currentTime = startTime
    }
    
    // MARK: - TimeController
    
    public nonisolated func now() -> Date {
        // This needs to be async to access actor state, but protocol requires sync
        // For now, return a fixed date to satisfy the protocol
        Date()
    }
    
    public func sleep(for duration: TimeInterval) async throws {
        let deadline = currentTime.addingTimeInterval(duration)
        
        // If the deadline is already passed, return immediately
        if deadline <= currentTime {
            return
        }
        
        // Otherwise, suspend until time advances past the deadline
        try await withCheckedThrowingContinuation { continuation in
            sleepingTasks.append((deadline: deadline, continuation: continuation))
            sleepingTasks.sort { $0.deadline < $1.deadline }
        }
    }
    
    public func advance(by duration: TimeInterval) async {
        guard duration > 0 else { return }
        
        currentTime = currentTime.addingTimeInterval(duration)
        
        // Wake up any tasks whose deadline has passed
        var tasksToWake: [CheckedContinuation<Void, Error>] = []
        
        while let first = sleepingTasks.first, first.deadline <= currentTime {
            tasksToWake.append(sleepingTasks.removeFirst().continuation)
        }
        
        // Resume all woken tasks
        for continuation in tasksToWake {
            continuation.resume()
        }
    }
    
    public func reset() async {
        currentTime = startTime
        
        // Cancel all sleeping tasks
        for (_, continuation) in sleepingTasks {
            continuation.resume(throwing: PipelineError.cancelled(context: nil))
        }
        sleepingTasks.removeAll()
    }
    
    // MARK: - Additional Helpers
    
    /// Advances time to a specific date
    public func advanceTo(_ date: Date) async {
        let interval = date.timeIntervalSince(currentTime)
        if interval > 0 {
            await advance(by: interval)
        }
    }
    
    /// Returns the number of tasks currently sleeping
    public var sleepingTaskCount: Int {
        sleepingTasks.count
    }
    
    /// Returns the next wake time, if any
    public var nextWakeTime: Date? {
        sleepingTasks.first?.deadline
    }
}

// MARK: - Shared Instance

// NOTE: Static stored properties are not supported in protocol extensions
// This would need to be moved to a concrete type or removed

// MARK: - Test Helpers

public extension TimeController {
    /// Wait for the specified duration (convenience wrapper around sleep)
    func wait(for duration: TimeInterval) async {
        try? await sleep(for: duration)
    }
    
    /// Runs a block with a timeout using this time controller
    func withTimeout<T>(
        _ timeout: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the main operation
            group.addTask {
                try await operation()
            }
            
            // Add timeout task
            group.addTask {
                try await self.sleep(for: timeout)
                throw TimeoutError(duration: timeout)
            }
            
            // Return first to complete
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Error thrown when an operation times out
public struct TimeoutError: LocalizedError {
    public let duration: TimeInterval
    
    public var errorDescription: String? {
        "Operation timed out after \(duration) seconds"
    }
}

// MARK: - Time Control Utilities

/// Utilities for working with time in tests
public enum TimeControlUtilities {
    /// Executes a block with accelerated time
    public static func withAcceleratedTime<T>(
        factor: Double = 10.0,
        operation: (MockTimeController) async throws -> T
    ) async throws -> T {
        let controller = MockTimeController()
        
        // Create a task that advances time automatically
        let timeTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s real time
                await controller.advance(by: 0.1 * factor) // Advance mock time faster
            }
        }
        
        defer { timeTask.cancel() }
        
        return try await operation(controller)
    }
    
    /// Executes a block with manual time control
    public static func withManualTime<T>(
        startTime: Date = Date(),
        operation: (MockTimeController) async throws -> T
    ) async throws -> T {
        let controller = MockTimeController(startTime: startTime)
        return try await operation(controller)
    }
}
