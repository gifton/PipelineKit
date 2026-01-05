//
//  PipelineAssertions.swift
//  PipelineKit
//
//  XCTest assertion helpers for pipeline testing.
//

import Foundation
import PipelineKit
import XCTest

// MARK: - Pipeline Assertions

/// Asserts that a pipeline execution succeeds and returns the expected result.
///
/// - Parameters:
///   - expression: The async throwing expression to evaluate.
///   - expected: The expected result value.
///   - message: An optional description of the failure.
///   - file: The file in which failure occurred.
///   - line: The line number on which failure occurred.
public func assertPipelineSucceeds<T: Equatable>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let result = try await expression()
        XCTAssertEqual(result, expected, message(), file: file, line: line)
    } catch {
        XCTFail("Pipeline unexpectedly failed with error: \(error). \(message())", file: file, line: line)
    }
}

/// Asserts that a pipeline execution fails with a specific error type.
///
/// - Parameters:
///   - expression: The async throwing expression to evaluate.
///   - errorType: The expected error type.
///   - message: An optional description of the failure.
///   - file: The file in which failure occurred.
///   - line: The line number on which failure occurred.
/// - Returns: The caught error if it matches the expected type.
@discardableResult
public func assertPipelineFails<T, E: Error>(
    _ expression: @autoclosure () async throws -> T,
    with errorType: E.Type,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async -> E? {
    do {
        _ = try await expression()
        XCTFail("Pipeline unexpectedly succeeded. Expected error of type \(E.self). \(message())", file: file, line: line)
        return nil
    } catch let error as E {
        return error
    } catch {
        XCTFail("Pipeline failed with unexpected error type: \(type(of: error)). Expected \(E.self). \(message())", file: file, line: line)
        return nil
    }
}

/// Asserts that a pipeline execution fails with a specific error.
///
/// - Parameters:
///   - expression: The async throwing expression to evaluate.
///   - expectedError: The expected error (must be Equatable).
///   - message: An optional description of the failure.
///   - file: The file in which failure occurred.
///   - line: The line number on which failure occurred.
public func assertPipelineFails<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    withError expectedError: E,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Pipeline unexpectedly succeeded. Expected error: \(expectedError). \(message())", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expectedError, message(), file: file, line: line)
    } catch {
        XCTFail("Pipeline failed with unexpected error: \(error). Expected: \(expectedError). \(message())", file: file, line: line)
    }
}

// MARK: - Context Assertions

public extension CommandContext {

    /// Asserts that the context contains a value for the given key.
    ///
    /// - Parameters:
    ///   - key: The context key to check.
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    /// - Returns: The value if present.
    @discardableResult
    func assertContains<T: Sendable>(
        _ key: ContextKey<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T? {
        let value: T? = self[key]
        guard let value else {
            XCTFail("Context does not contain value for key: \(key.name)", file: file, line: line)
            return nil
        }
        return value
    }

    /// Asserts that the context contains the expected value for the given key.
    ///
    /// - Parameters:
    ///   - key: The context key to check.
    ///   - expected: The expected value.
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    func assertValue<T: Sendable & Equatable>(
        for key: ContextKey<T>,
        equals expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value: T? = self[key]
        guard let value else {
            XCTFail("Context does not contain value for key: \(key.name)", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, "Context value mismatch for key: \(key.name)", file: file, line: line)
    }

    /// Asserts that the context does not contain a value for the given key.
    ///
    /// - Parameters:
    ///   - key: The context key to check.
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    func assertDoesNotContain<T: Sendable>(
        _ key: ContextKey<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value: T? = self[key]
        if value != nil {
            XCTFail("Context unexpectedly contains value for key: \(key.name)", file: file, line: line)
        }
    }
}

// MARK: - Middleware Assertions

public extension CapturingMiddleware {

    /// Asserts that the middleware was called exactly the specified number of times.
    ///
    /// - Parameters:
    ///   - count: The expected execution count.
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    func assertExecutedTimes(
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            executionCount,
            count,
            "Expected middleware to be called \(count) times, but was called \(executionCount) times",
            file: file,
            line: line
        )
    }

    /// Asserts that the middleware was called at least once.
    ///
    /// - Parameters:
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    func assertWasCalled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(
            executionCount,
            0,
            "Expected middleware to be called at least once",
            file: file,
            line: line
        )
    }

    /// Asserts that the middleware was never called.
    ///
    /// - Parameters:
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    func assertWasNotCalled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            executionCount,
            0,
            "Expected middleware to never be called, but was called \(executionCount) times",
            file: file,
            line: line
        )
    }

    /// Asserts that a specific command type was executed.
    ///
    /// - Parameters:
    ///   - commandType: The expected command type.
    ///   - file: The file in which failure occurred.
    ///   - line: The line number on which failure occurred.
    func assertExecuted<T: Command>(
        _ commandType: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let typeName = String(describing: T.self)
        let found = executedCommands.contains { $0.commandType == typeName }
        XCTAssertTrue(
            found,
            "Expected command type \(typeName) to be executed",
            file: file,
            line: line
        )
    }
}

// MARK: - Timing Assertions

/// Asserts that an async operation completes within the specified time limit.
///
/// - Parameters:
///   - seconds: Maximum allowed duration in seconds.
///   - expression: The async expression to evaluate.
///   - message: An optional description of the failure.
///   - file: The file in which failure occurred.
///   - line: The line number on which failure occurred.
/// - Returns: The result of the expression if it completes in time.
@discardableResult
public func assertCompletesWithin<T>(
    _ seconds: TimeInterval,
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows -> T {
    let start = Date()
    let result = try await expression()
    let duration = Date().timeIntervalSince(start)

    XCTAssertLessThan(
        duration,
        seconds,
        "Operation took \(duration)s, expected less than \(seconds)s. \(message())",
        file: file,
        line: line
    )

    return result
}

/// Asserts that an async operation takes at least the specified time.
///
/// - Parameters:
///   - seconds: Minimum expected duration in seconds.
///   - expression: The async expression to evaluate.
///   - message: An optional description of the failure.
///   - file: The file in which failure occurred.
///   - line: The line number on which failure occurred.
/// - Returns: The result of the expression.
@discardableResult
public func assertTakesAtLeast<T>(
    _ seconds: TimeInterval,
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows -> T {
    let start = Date()
    let result = try await expression()
    let duration = Date().timeIntervalSince(start)

    XCTAssertGreaterThanOrEqual(
        duration,
        seconds,
        "Operation took \(duration)s, expected at least \(seconds)s. \(message())",
        file: file,
        line: line
    )

    return result
}
