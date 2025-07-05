import Foundation
import Atomics

/// Analyzes and executes middleware in parallel when safe
public struct ParallelMiddlewareExecutor {
    /// Dependency graph for middleware
    public struct DependencyGraph {
        private var dependencies: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        
        /// Add a dependency relationship
        public mutating func addDependency(
            from dependent: any Middleware.Type,
            to dependency: any Middleware.Type
        ) {
            let dependentId = ObjectIdentifier(dependent)
            let dependencyId = ObjectIdentifier(dependency)
            
            dependencies[dependentId, default: []].insert(dependencyId)
        }
        
        /// Get all dependencies for a middleware type
        public func dependencies(for middleware: any Middleware.Type) -> Set<ObjectIdentifier> {
            dependencies[ObjectIdentifier(middleware)] ?? []
        }
        
        /// Check if two middleware can run in parallel
        public func canRunInParallel(_ m1: any Middleware, _ m2: any Middleware) -> Bool {
            let id1 = ObjectIdentifier(type(of: m1))
            let id2 = ObjectIdentifier(type(of: m2))
            
            // Check if either depends on the other
            let m1Deps = dependencies[id1] ?? []
            let m2Deps = dependencies[id2] ?? []
            
            return !m1Deps.contains(id2) && !m2Deps.contains(id1)
        }
        
        /// Group middleware into parallel execution stages
        public func computeParallelStages(_ middlewares: [any Middleware]) -> [[any Middleware]] {
            var stages: [[any Middleware]] = []
            var processed = Set<ObjectIdentifier>()
            
            for middleware in middlewares {
                let id = ObjectIdentifier(type(of: middleware))
                if processed.contains(id) { continue }
                
                // Find all middleware that can run in parallel with this one
                var currentStage: [any Middleware] = [middleware]
                processed.insert(id)
                
                for other in middlewares {
                    let otherId = ObjectIdentifier(type(of: other))
                    if processed.contains(otherId) { continue }
                    
                    // Check if it can run in parallel with all in current stage
                    let canAddToStage = currentStage.allSatisfy { staged in
                        canRunInParallel(staged, other)
                    }
                    
                    if canAddToStage {
                        currentStage.append(other)
                        processed.insert(otherId)
                    }
                }
                
                stages.append(currentStage)
            }
            
            return stages
        }
    }
    
    /// Default dependency relationships
    public static var defaultDependencies: DependencyGraph {
        var graph = DependencyGraph()
        
        // Add known dependencies here
        // For example:
        // graph.addDependency(from: AuthorizationMiddleware.self, to: AuthenticationMiddleware.self)
        
        return graph
    }
}

/// Pipeline that executes independent middleware in parallel
public actor ParallelPipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    private let handler: H
    private var middlewares: [any Middleware] = []
    private let dependencyGraph: ParallelMiddlewareExecutor.DependencyGraph
    private var parallelStages: [[any Middleware]] = []
    
    public init(
        handler: H,
        dependencyGraph: ParallelMiddlewareExecutor.DependencyGraph = .defaultDependencies
    ) {
        self.handler = handler
        self.dependencyGraph = dependencyGraph
    }
    
    /// Add middleware and recompute parallel stages
    public func addMiddleware(_ middleware: any Middleware) {
        middlewares.append(middleware)
        parallelStages = dependencyGraph.computeParallelStages(middlewares)
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.invalidCommandType(command: command)
        }
        
        let result = try await executeWithParallelMiddleware(typedCommand, context: context)
        
        guard let typedResult = result as? T.Result else {
            throw PipelineError(
                underlyingError: InvalidResultTypeError(),
                command: command
            )
        }
        
        return typedResult
    }
    
    private func executeWithParallelMiddleware(
        _ command: C,
        context: CommandContext
    ) async throws -> C.Result {
        // Create the final handler function
        var next: @Sendable (C, CommandContext) async throws -> C.Result = { cmd, ctx in
            try await self.handler.handle(cmd)
        }
        
        // Build middleware chain with parallel execution
        for stage in parallelStages.reversed() {
            let currentNext = next
            
            if stage.count == 1 {
                // Single middleware - execute normally
                let middleware = stage[0]
                next = { cmd, ctx in
                    try await middleware.execute(cmd, context: ctx, next: currentNext)
                }
            } else {
                // Multiple middleware - execute in parallel
                next = { cmd, ctx in
                    try await self.executeParallelStage(
                        stage,
                        command: cmd,
                        context: ctx,
                        next: currentNext
                    )
                }
            }
        }
        
        return try await next(command, context)
    }
    
    private func executeParallelStage<T: Command>(
        _ middlewares: [any Middleware],
        command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // For middleware that only performs side effects (logging, metrics),
        // we can run them in parallel and continue
        
        let (sideEffectMiddleware, transformingMiddleware) = categorizeMiddleware(middlewares)
        
        // Run side-effect middleware in parallel
        await withTaskGroup(of: Void.self) { group in
            for middleware in sideEffectMiddleware {
                group.addTask {
                    // Create a no-op next function for side-effect middleware
                    let noOpNext: @Sendable (T, CommandContext) async throws -> T.Result = { _, _ in
                        // Return a dummy result - won't be used
                        fatalError("Side-effect middleware should not call next")
                    }
                    
                    // Ignore the result
                    _ = try? await middleware.execute(command, context: context, next: noOpNext)
                }
            }
        }
        
        // For transforming middleware, we need a different strategy
        // Run them sequentially for now (could be optimized with speculation)
        var currentNext = next
        for middleware in transformingMiddleware.reversed() {
            let capturedNext = currentNext
            currentNext = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: capturedNext)
            }
        }
        
        return try await currentNext(command, context)
    }
    
    private func categorizeMiddleware(_ middlewares: [any Middleware]) -> (sideEffect: [any Middleware], transforming: [any Middleware]) {
        // In a real implementation, we'd have a protocol or metadata to identify
        // side-effect vs transforming middleware
        var sideEffect: [any Middleware] = []
        var transforming: [any Middleware] = []
        
        for middleware in middlewares {
            // Heuristic: certain middleware types are known to be side-effect only
            let typeName = String(describing: type(of: middleware))
            if typeName.contains("Logging") || 
               typeName.contains("Metrics") || 
               typeName.contains("Observability") ||
               typeName.contains("Tracing") ||
               typeName.contains("Monitoring") {
                sideEffect.append(middleware)
            } else {
                transforming.append(middleware)
            }
        }
        
        return (sideEffect, transforming)
    }
}

private struct InvalidResultTypeError: LocalizedError {
    var errorDescription: String? {
        "Invalid result type returned from pipeline"
    }
}