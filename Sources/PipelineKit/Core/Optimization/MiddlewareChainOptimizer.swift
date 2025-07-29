import Foundation

/// Optimizes middleware chains for improved performance through pre-compilation
/// and execution path optimization.
///
/// The optimizer analyzes middleware chains to:
/// - Pre-compile execution paths
/// - Eliminate redundant checks
/// - Optimize context access patterns
/// - Create specialized fast paths for common scenarios
///
/// Thread-safe through actor isolation for all mutable state
public actor MiddlewareChainOptimizer {
    
    /// Represents a pre-compiled middleware chain
    public struct OptimizedChain: Sendable {
        /// The original middleware in execution order
        let middleware: [any Middleware]
        
        /// Pre-computed execution strategy
        let strategy: ExecutionStrategy
        
        /// Cached metadata about the chain
        let metadata: ChainMetadata
        
        /// Fast-path executor for common cases
        let fastPathExecutor: FastPathExecutor?
    }
    
    /// Execution strategies for optimized chains
    public enum ExecutionStrategy: Sendable {
        /// Sequential execution with no special optimizations
        case sequential
        
        /// Some middleware can execute in parallel
        case partiallyParallel(groups: [ParallelGroup])
        
        /// All middleware are side-effect only
        case fullyParallel
        
        /// Chain has validation-only middleware that can fail fast
        case failFast(validators: [Int])
        
        /// Mixed strategy with multiple optimization opportunities
        case hybrid(HybridStrategy)
    }
    
    /// Metadata about the middleware chain
    public struct ChainMetadata: Sendable {
        /// Total number of middleware
        let count: Int
        
        /// Number of middleware that modify context
        let contextModifiers: Int
        
        /// Number of middleware that only read context
        let contextReaders: Int
        
        /// Whether any middleware can throw errors
        let canThrow: Bool
        
        /// Average execution time (if profiled)
        var averageExecutionTime: TimeInterval?
        
        /// Memory allocation pattern
        let allocationPattern: AllocationPattern
    }
    
    /// Memory allocation patterns
    public enum AllocationPattern: Sendable {
        case none
        case light
        case moderate
        case heavy
    }
    
    /// Groups of middleware that can execute in parallel
    public struct ParallelGroup: Sendable {
        let startIndex: Int
        let endIndex: Int
        let middleware: [any Middleware]
    }
    
    /// Hybrid execution strategy
    public struct HybridStrategy: Sendable {
        let validationPhase: [Int]?
        let parallelPhase: ParallelGroup?
        let sequentialPhase: [Int]
    }
    
    /// Fast path executor for common scenarios
    public struct FastPathExecutor: Sendable {
        private let middleware: [any Middleware]
        private let executorFunc: @Sendable (Any, CommandContext, @escaping @Sendable (Any) async throws -> Any) async throws -> Any
        
        init(
            middleware: [any Middleware],
            executorFunc: @escaping @Sendable (Any, CommandContext, @escaping @Sendable (Any) async throws -> Any) async throws -> Any
        ) {
            self.middleware = middleware
            self.executorFunc = executorFunc
        }
        
        func execute<T: Command>(_ command: T, context: CommandContext, handler: @escaping @Sendable (T) async throws -> T.Result) async throws -> T.Result {
            let result = try await executorFunc(command, context) { processedCommand in
                guard let typedCommand = processedCommand as? T else {
                    throw OptimizationError.typeMismatch
                }
                let handlerResult = try await handler(typedCommand)
                return handlerResult as Any
            }
            
            guard let typedResult = result as? T.Result else {
                throw OptimizationError.typeMismatch
            }
            
            return typedResult
        }
    }
    
    private let profiler: MiddlewareProfiler?
    
    public init(profiler: MiddlewareProfiler? = nil) {
        self.profiler = profiler
    }
    
    /// Analyzes and optimizes a middleware chain
    public func optimize(
        middleware: [any Middleware],
        handler: (any CommandHandler)?
    ) -> OptimizedChain {
        let metadata = analyzeChain(middleware)
        let strategy = determineStrategy(middleware, metadata: metadata)
        let fastPath = createFastPath(middleware: middleware, strategy: strategy)
        
        return OptimizedChain(
            middleware: middleware,
            strategy: strategy,
            metadata: metadata,
            fastPathExecutor: fastPath
        )
    }
    
    private func analyzeChain(_ middleware: [any Middleware]) -> ChainMetadata {
        var contextModifiers = 0
        var contextReaders = 0
        var canThrow = false
        
        // Analyze each middleware
        for mw in middleware {
            // In a real implementation, we'd use reflection or
            // protocol requirements to determine these properties
            
            // For now, use heuristics based on priority
            switch mw.priority {
            case .authentication, .validation:
                canThrow = true
                contextReaders += 1
            case .preProcessing, .processing:
                contextModifiers += 1
                canThrow = true
            case .postProcessing, .errorHandling:
                contextReaders += 1
            case .custom:
                // Conservative assumption
                contextModifiers += 1
                canThrow = true
            }
        }
        
        let allocationPattern: AllocationPattern
        if contextModifiers == 0 {
            allocationPattern = .none
        } else if contextModifiers <= 2 {
            allocationPattern = .light
        } else if contextModifiers <= 5 {
            allocationPattern = .moderate
        } else {
            allocationPattern = .heavy
        }
        
        return ChainMetadata(
            count: middleware.count,
            contextModifiers: contextModifiers,
            contextReaders: contextReaders,
            canThrow: canThrow,
            averageExecutionTime: nil,
            allocationPattern: allocationPattern
        )
    }
    
    private func determineStrategy(
        _ middleware: [any Middleware],
        metadata: ChainMetadata
    ) -> ExecutionStrategy {
        // Empty chain
        if middleware.isEmpty {
            return .sequential
        }
        
        // Single middleware
        if middleware.count == 1 {
            return .sequential
        }
        
        // Check for validation-heavy chains
        let validators = middleware.enumerated().compactMap { index, mw in
            mw.priority == .validation ? index : nil
        }
        
        if validators.count > middleware.count / 2 {
            return .failFast(validators: validators)
        }
        
        // Check for parallel opportunities
        let parallelGroups = identifyParallelGroups(middleware)
        if !parallelGroups.isEmpty {
            if parallelGroups.count == 1 && 
               parallelGroups[0].middleware.count == middleware.count {
                return .fullyParallel
            }
            return .partiallyParallel(groups: parallelGroups)
        }
        
        // Default to sequential
        return .sequential
    }
    
    private func identifyParallelGroups(_ middleware: [any Middleware]) -> [ParallelGroup] {
        var groups: [ParallelGroup] = []
        var currentGroup: [any Middleware] = []
        var startIndex = 0
        
        for (index, mw) in middleware.enumerated() {
            // Middleware that typically don't depend on each other
            if mw.priority == .postProcessing || mw.priority == .errorHandling {
                if currentGroup.isEmpty {
                    startIndex = index
                }
                currentGroup.append(mw)
            } else {
                // End current group if any
                if !currentGroup.isEmpty && currentGroup.count > 1 {
                    groups.append(ParallelGroup(
                        startIndex: startIndex,
                        endIndex: startIndex + currentGroup.count - 1,
                        middleware: currentGroup
                    ))
                }
                currentGroup = []
            }
        }
        
        // Handle final group
        if !currentGroup.isEmpty && currentGroup.count > 1 {
            groups.append(ParallelGroup(
                startIndex: startIndex,
                endIndex: startIndex + currentGroup.count - 1,
                middleware: currentGroup
            ))
        }
        
        return groups
    }
    
    private func createFastPath(
        middleware: [any Middleware],
        strategy: ExecutionStrategy
    ) -> FastPathExecutor? {
        // Only create fast path for simple sequential chains
        guard case .sequential = strategy,
              middleware.count <= 3 else {
            return nil
        }
        
        // Generate specialized execution code based on middleware count
        switch middleware.count {
        case 0:
            // Direct handler execution - no middleware to execute
            return FastPathExecutor(
                middleware: middleware,
                executorFunc: { command, context, handler in
                    // No middleware, directly call handler
                    return try await handler(command)
                }
            )
            
        case 1:
            // Single middleware optimization
            let mw = middleware[0]
            return FastPathExecutor(
                middleware: middleware,
                executorFunc: { command, context, handler in
                    // Use a type-erased wrapper to handle the Command constraint
                    struct TypeErasedCommand: Command {
                        typealias Result = Any
                        let wrapped: Any
                    }
                    
                    let wrapped = TypeErasedCommand(wrapped: command)
                    let result = try await mw.execute(wrapped, context: context) { cmd, ctx in
                        try await handler((cmd as! TypeErasedCommand).wrapped)
                    }
                    return result
                }
            )
            
        case 2:
            // Two middleware optimization
            let mw1 = middleware[0]
            let mw2 = middleware[1]
            return FastPathExecutor(
                middleware: middleware,
                executorFunc: { command, context, handler in
                    // Use a type-erased wrapper to handle the Command constraint
                    struct TypeErasedCommand: Command {
                        typealias Result = Any
                        let wrapped: Any
                    }
                    
                    let wrapped = TypeErasedCommand(wrapped: command)
                    let result = try await mw1.execute(wrapped, context: context) { cmd1, ctx1 in
                        try await mw2.execute(cmd1, context: ctx1) { cmd2, ctx2 in
                            try await handler((cmd2 as! TypeErasedCommand).wrapped)
                        }
                    }
                    return result
                }
            )
            
        case 3:
            // Three middleware optimization
            let mw1 = middleware[0]
            let mw2 = middleware[1]
            let mw3 = middleware[2]
            return FastPathExecutor(
                middleware: middleware,
                executorFunc: { command, context, handler in
                    // Use a type-erased wrapper to handle the Command constraint
                    struct TypeErasedCommand: Command {
                        typealias Result = Any
                        let wrapped: Any
                    }
                    
                    let wrapped = TypeErasedCommand(wrapped: command)
                    let result = try await mw1.execute(wrapped, context: context) { cmd1, ctx1 in
                        try await mw2.execute(cmd1, context: ctx1) { cmd2, ctx2 in
                            try await mw3.execute(cmd2, context: ctx2) { cmd3, ctx3 in
                                try await handler((cmd3 as! TypeErasedCommand).wrapped)
                            }
                        }
                    }
                    return result
                }
            )
            
        default:
            // Should not reach here due to guard condition
            return nil
        }
    }
}

/// Profiler for collecting middleware execution statistics
/// Must be Sendable for use with actor-based optimizer
public protocol MiddlewareProfiler: Sendable {
    func recordExecution(
        middleware: any Middleware,
        duration: TimeInterval,
        success: Bool
    )
    
    func getAverageExecutionTime(for middleware: any Middleware) -> TimeInterval?
}

/// Errors that can occur during optimization
public enum OptimizationError: Error {
    case typeMismatch
    case unsupportedConfiguration
}

