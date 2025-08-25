//
//  TestContextKeys.swift
//  PipelineKit
//
//  Helper for test context keys using the new ContextKey<T> API
//

import Foundation
import PipelineKit

/// Common test context keys for use across test suites
public enum TestContextKeys {
    // MARK: - Basic Type Keys
    /// String value test key
    public static let testKey = ContextKey<String>("test_key")

    /// Integer value test key
    public static let numberKey = ContextKey<Int>("number_key")

    /// Boolean value test key
    public static let boolKey = ContextKey<Bool>("bool_key")

    /// Double value test key
    public static let doubleKey = ContextKey<Double>("double_key")

    /// Array test key
    public static let arrayKey = ContextKey<[String]>("array_key")

    /// Dictionary test key
    public static let dictKey = ContextKey<[String: String]>("dict_key")

    /// Date test key
    public static let dateKey = ContextKey<Date>("date_key")

    /// Optional string test key
    public static let optionalKey = ContextKey<String?>("optional_key")

    /// Generic middleware test key
    public static let middlewareKey = ContextKey<String>("middleware_key")

    /// User data test key - commented out due to Sendable constraints
    // public static let userDataKey = ContextKey<[String: Any]>("user_data")

    /// Counter test key for concurrent access tests
    public static let counterKey = ContextKey<Int>("counter")

    /// State test key for state tracking
    public static let stateKey = ContextKey<String>("state")

    // MARK: - Dynamic Key Generation

    /// Creates a string key with a suffix
    public static func key(_ suffix: String) -> ContextKey<String> {
        ContextKey<String>("key.\(suffix)")
    }

    /// Creates a number key with a suffix
    public static func number(_ suffix: String) -> ContextKey<Int> {
        ContextKey<Int>("number.\(suffix)")
    }

    /// Creates a dynamic key for any type
    public static func dynamic<T>(_ name: String) -> ContextKey<T> {
        ContextKey<T>(name)
    }

    // MARK: - Common Test Keys

    public static let userID = ContextKey<String>("user_id")
    public static let authToken = ContextKey<String>("auth_token")
    public static let requestID = ContextKey<String>("request_id")
    public static let sessionID = ContextKey<String>("session_id")
    public static let traceID = ContextKey<String>("trace_id")
    public static let spanID = ContextKey<String>("span_id")
    public static let testValue = ContextKey<String>("test_value")
    public static let testCustomValue = ContextKey<String>("test_custom_value")
}

