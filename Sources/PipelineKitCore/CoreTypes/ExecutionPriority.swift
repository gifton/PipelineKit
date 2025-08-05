import Foundation

/// Simplified middleware execution priorities.
/// 
/// These values provide a consistent ordering for middleware execution.
/// Lower values execute earlier in the pipeline.
/// 
/// Example usage:
/// ```swift
/// struct MyMiddleware: Middleware {
///     let priority = ExecutionPriority.processing
/// }
/// ```
@frozen
public enum ExecutionPriority: Int, Sendable, CaseIterable {
    /// Authentication and security checks (first)
    case authentication = 100
    
    /// Input validation and sanitization
    case validation = 200
    
    /// Pre-processing (transformation, decompression)
    case preProcessing = 300
    
    /// Main business logic processing
    case processing = 400
    
    /// Post-processing (caching, metrics, logging)
    case postProcessing = 500
    
    /// Error handling and recovery
    case errorHandling = 600
    
    /// Custom user-defined priority
    case custom = 1000
}

// MARK: - Convenience Methods

public extension ExecutionPriority {
    /// Creates a custom priority value between two standard priorities.
    /// 
    /// Example:
    /// ```swift
    /// let customPriority = ExecutionPriority.between(.authentication, and: .validation)
    /// // Returns 150 (between 100 and 200)
    /// ```
    @inlinable
    static func between(_ first: ExecutionPriority, and second: ExecutionPriority) -> Int {
        let lower = min(first.rawValue, second.rawValue)
        let upper = max(first.rawValue, second.rawValue)
        return lower + (upper - lower) / 2
    }
    
    /// Creates a custom priority value just before the specified priority.
    @inlinable
    static func before(_ priority: ExecutionPriority) -> Int {
        priority.rawValue - 1
    }
    
    /// Creates a custom priority value just after the specified priority.
    @inlinable
    static func after(_ priority: ExecutionPriority) -> Int {
        priority.rawValue + 1
    }
    
    /// Returns a human-readable description of the priority.
    var description: String {
        switch self {
        case .authentication:
            return "Authentication"
        case .validation:
            return "Validation"
        case .preProcessing:
            return "Pre-Processing"
        case .processing:
            return "Processing"
        case .postProcessing:
            return "Post-Processing"
        case .errorHandling:
            return "Error Handling"
        case .custom:
            return "Custom"
        }
    }
}
