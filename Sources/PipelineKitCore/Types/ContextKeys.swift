import Foundation

// MARK: - Context Keys Namespace

/// Namespace for all context keys used in PipelineKit.
/// 
/// This enum provides a hierarchical organization of context keys,
/// making them easier to discover and use.
/// 
/// Example:
/// ```swift
/// context.set("user123", for: ContextKeys.Auth.UserID.self)
/// let userId = context.get(ContextKeys.Auth.UserID.self)
/// ```
public enum ContextKeys {
    
    // MARK: - Authentication & Authorization
    
    /// Authentication-related context keys
    public enum Auth {
        /// Context key for storing authenticated user information.
        public struct UserID: ContextKey {
            public typealias Value = String
        }
        
        /// Context key for storing authorization roles.
        public struct Roles: ContextKey {
            public typealias Value = Set<String>
        }
    }
    
    // MARK: - Request Metadata
    
    /// Request-related context keys
    public enum Request {
        /// Context key for storing request start time.
        public struct StartTime: ContextKey {
            public typealias Value = Date
        }
        
        /// Context key for storing request ID for tracing.
        public struct ID: ContextKey {
            public typealias Value = String
        }
    }
    
    // MARK: - Tracing & Observability
    
    /// Tracing and observability context keys
    public enum Tracing {
        /// Context key for storing trace ID for distributed tracing.
        public struct TraceID: ContextKey {
            public typealias Value = String
        }
        
        /// Context key for storing service name for observability.
        public struct ServiceName: ContextKey {
            public typealias Value = String
        }
    }
    
    // MARK: - Feature Management
    
    /// Feature flag context keys
    public enum Features {
        /// Context key for storing feature flags.
        public struct Flags: ContextKey {
            public typealias Value = Set<String>
        }
    }
}

