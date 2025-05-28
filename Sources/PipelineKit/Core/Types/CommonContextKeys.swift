import Foundation

// MARK: - Common Context Keys

/// Context key for storing authenticated user information.
public struct AuthenticatedUserKey: ContextKey {
    public typealias Value = String // User ID
}

/// Context key for storing request start time.
public struct RequestStartTimeKey: ContextKey {
    public typealias Value = Date
}

/// Context key for storing request ID for tracing.
public struct RequestIDKey: ContextKey {
    public typealias Value = String
}

/// Context key for storing feature flags.
public struct FeatureFlagsKey: ContextKey {
    public typealias Value = Set<String>
}

/// Context key for storing authorization roles.
public struct AuthorizationRolesKey: ContextKey {
    public typealias Value = Set<String>
}