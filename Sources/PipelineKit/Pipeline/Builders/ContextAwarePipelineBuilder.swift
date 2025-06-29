import Foundation

/// Builder actor for constructing context-aware pipelines with thread-safe fluent API.
@available(*, deprecated, renamed: "PipelineBuilder",
           message: "Use PipelineBuilder instead.")
public actor ContextAwarePipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    private let handler: H
    private var middlewares: [any Middleware] = []
    private var maxDepth: Int = 100
    
    public init(handler: H) {
        self.handler = handler
    }
    
    @discardableResult
    public func with(_ middleware: any Middleware) -> Self {
        middlewares.append(middleware)
        return self
    }
    
    @discardableResult
    public func with(_ newMiddlewares: [any Middleware]) -> Self {
        middlewares.append(contentsOf: newMiddlewares)
        return self
    }
    
    @discardableResult
    public func withMaxDepth(_ depth: Int) -> Self {
        self.maxDepth = depth
        return self
    }
    
    public func build() async throws -> ContextAwarePipeline {
        let pipeline = ContextAwarePipeline(handler: handler, maxDepth: maxDepth)
        
        for middleware in middlewares {
            try await pipeline.addMiddleware(middleware)
        }
        
        return pipeline
    }
}