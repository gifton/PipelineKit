import Foundation

// MARK: - Context Keys Namespace

/// Namespace for all context keys used in PipelineKit.
/// 
/// This enum provides a hierarchical organization of context keys,
/// making them easier to discover and use.
/// 
/// Example:
/// ```swift
/// context.set("user123", for: ContextKeys.AuthUserID.self)
/// let userId = context.get(ContextKeys.AuthUserID.self)
/// ```
public enum ContextKeys {
    // MARK: - Authentication & Authorization
    
    /// Context key for storing authenticated user information.
    public struct AuthUserID: ContextKey {
        public typealias Value = String
    }
    
    /// Context key for storing authorization roles.
    public struct AuthRoles: ContextKey {
        public typealias Value = Set<String>
    }
    
    // MARK: - Request Metadata
    
    /// Context key for storing request start time.
    public struct RequestStartTime: ContextKey {
        public typealias Value = Date
    }
    
    /// Context key for storing request identifier for tracing.
    public struct RequestID: ContextKey {
        public typealias Value = String
    }
    
    // MARK: - Tracing & Observability
    
    /// Context key for storing trace ID for distributed tracing.
    public struct TracingTraceID: ContextKey {
        public typealias Value = String
    }
    
    /// Context key for storing service name for observability.
    public struct TracingServiceName: ContextKey {
        public typealias Value = String
    }
    
    // MARK: - Feature Management
    
    /// Context key for storing feature flags.
    public struct FeaturesFlags: ContextKey {
        public typealias Value = Set<String>
    }
    
    // MARK: - Namespace Aliases (for backwards compatibility)
    
    /// Authentication-related context keys
    public enum Auth {
        public typealias UserID = AuthUserID
        public typealias Roles = AuthRoles
    }
    
    /// Request-related context keys
    public enum Request {
        public typealias StartTime = RequestStartTime
        public typealias RequestID = ContextKeys.RequestID
    }
    
    /// Tracing and observability context keys
    public enum Tracing {
        public typealias TraceID = TracingTraceID
        public typealias ServiceName = TracingServiceName
    }
    
    /// Feature flag context keys
    public enum Features {
        public typealias Flags = FeaturesFlags
    }
}
