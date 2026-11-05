//
//  TimeoutTester.swift
//  PipelineKit
//
//  Utility for simulating timeout and delay scenarios in tests.
//

import Foundation
import PipelineKit

/// Stateless test utility for validating cooperative timeout behavior.
public final class TimeoutTester: Sendable {
    private enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case deadline
    }

    public init() {}

    /// Sleep for one second longer than the supplied duration.
    public func operationThatWillTimeout(after timeout: TimeInterval) async throws {
        _ = NumericDuration.nanoseconds(timeout)
        try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(timeout + 1))
    }

    /// Sleep for eighty percent of the supplied duration.
    public func operationThatCompletesJustInTime(before timeout: TimeInterval) async throws {
        _ = NumericDuration.nanoseconds(timeout)
        try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(timeout * 0.8))
    }

    /// Sleep for a finite, nonnegative duration representable in nanoseconds.
    public func operation(withDelay delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(delay))
    }

    /// Race an operation against a cooperative deadline.
    ///
    /// An owned deadline throws `PipelineError.timeout`; operation errors propagate.
    /// The losing child is cancelled and joined before return. Work that ignores
    /// cancellation can therefore delay return beyond the deadline. Use an external
    /// process watchdog for tests involving uncooperative work.
    public func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        switch try await race(timeout, operation: operation) {
        case .value(let value): return value
        case .deadline: throw PipelineError.timeout(duration: timeout, context: nil)
        }
    }

    /// Return true only when this helper's deadline wins the race.
    /// Operation-thrown cancellation and timeout errors return false.
    /// Like `withTimeout`, this waits for both children to settle.
    public func expectTimeout<T: Sendable>(
        within timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async -> Bool {
        do {
            if case .deadline = try await race(timeout, operation: operation) { return true }
            return false
        } catch {
            return false
        }
    }

    private func race<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> Outcome<T> {
        let nanoseconds: UInt64 = NumericDuration.nanoseconds(timeout)
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Outcome<T>.self) { group in
            defer { group.cancelAll() }
            group.addTask { .value(try await operation()) }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                return .deadline
            }
            return try await group.next()!
        }
    }

    /// Sleep for the duration, then run the supplied operation.
    public func runWithTimeout(_ timeout: TimeInterval, operation: () async throws -> Void = {}) async throws {
        try await Task.sleep(nanoseconds: NumericDuration.nanoseconds(timeout))
        try await operation()
    }
}
