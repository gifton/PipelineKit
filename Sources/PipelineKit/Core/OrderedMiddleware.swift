import Foundation

/// Protocol for middleware that has a recommended execution order.
/// 
/// Middleware implementing this protocol provides a recommended
/// `MiddlewareOrder` to ensure proper execution sequence in the pipeline.
/// 
/// Example:
/// ```swift
/// struct MyMiddleware: Middleware, OrderedMiddleware {
///     static var recommendedOrder: MiddlewareOrder { .validation }
///     
///     func execute<T: Command>(...) async throws -> T.Result {
///         // Implementation
///     }
/// }
/// ```
public protocol OrderedMiddleware: Middleware {
    /// The recommended execution order for this middleware
    static var recommendedOrder: MiddlewareOrder { get }
}

/// Extension to make it easier to add ordered middleware to pipelines
extension PriorityPipeline {
    /// Adds middleware using its recommended order.
    /// 
    /// - Parameter middleware: The ordered middleware to add
    /// - Throws: PipelineError.maxDepthExceeded if limit is reached
    public func addOrderedMiddleware<M: OrderedMiddleware>(_ middleware: M) throws {
        try addMiddleware(middleware, priority: M.recommendedOrder.rawValue)
    }
}

/// Builder extension for ordered middleware
extension MiddlewareOrderBuilder {
    /// Adds ordered middleware using its recommended order.
    /// 
    /// - Parameter middleware: The ordered middleware to add
    public mutating func addOrdered<M: OrderedMiddleware>(_ middleware: M) {
        add(middleware, order: M.recommendedOrder)
    }
}

/// Helper to create a properly ordered pipeline with security best practices
public struct SecurePipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    private let handler: H
    private var builder = MiddlewareOrderBuilder()
    
    public init(handler: H) {
        self.handler = handler
    }
    
    /// Adds standard security middleware in the correct order
    @discardableResult
    public mutating func withStandardSecurity() -> Self {
        // Add in security-first order
        builder.add(ValidationMiddleware(), order: .validation)
        builder.add(SanitizationMiddleware(), order: .sanitization)
        return self
    }
    
    /// Adds authentication middleware
    @discardableResult
    public mutating func withAuthentication(_ middleware: any Middleware) -> Self {
        builder.add(middleware, order: .authentication)
        return self
    }
    
    /// Adds authorization middleware
    @discardableResult
    public mutating func withAuthorization(_ middleware: any Middleware) -> Self {
        builder.add(middleware, order: .authorization)
        return self
    }
    
    /// Adds rate limiting middleware
    @discardableResult
    public mutating func withRateLimiting(_ middleware: any Middleware) -> Self {
        builder.add(middleware, order: .rateLimiting)
        return self
    }
    
    /// Adds logging middleware
    @discardableResult
    public mutating func withLogging(_ middleware: any Middleware) -> Self {
        builder.add(middleware, order: .logging)
        return self
    }
    
    /// Adds custom middleware with specific order
    @discardableResult
    public mutating func with(_ middleware: any Middleware, order: MiddlewareOrder) -> Self {
        builder.add(middleware, order: order)
        return self
    }
    
    /// Builds a priority pipeline with all middleware in the correct order
    public func build() async throws -> PriorityPipeline {
        let pipeline = PriorityPipeline(handler: handler)
        let orderedMiddleware = builder.build()
        
        for (middleware, priority) in orderedMiddleware {
            try await pipeline.addMiddleware(middleware, priority: priority)
        }
        
        return pipeline
    }
}
