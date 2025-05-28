import Foundation

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
    public mutating func with(_ middleware: any Middleware, order: ExecutionPriority) -> Self {
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