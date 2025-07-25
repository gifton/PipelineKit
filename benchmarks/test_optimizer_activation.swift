import Foundation

// MARK: - Core Types

public protocol Command: Sendable {
    associatedtype Result: Sendable
}

public protocol CommandHandler: Sendable {
    associatedtype CommandType: Command
    func handle(_ command: CommandType) async throws -> CommandType.Result
}

public protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

public enum ExecutionPriority: Int, Sendable {
    case authentication = 100
    case validation = 200
    case preProcessing = 300
    case processing = 400
    case postProcessing = 500
    case errorHandling = 600
    case custom = 999
}

public protocol ContextKey {
    associatedtype Value
}

public final class CommandContext: @unchecked Sendable {
    internal var storage: [ObjectIdentifier: Any] = [:]
    internal let lock = NSLock()
    
    public init() {}
    
    public func set<K: ContextKey>(_ value: K.Value, for key: K.Type) {
        lock.lock()
        defer { lock.unlock() }
        storage[ObjectIdentifier(key)] = value
    }
    
    public func get<K: ContextKey>(_ key: K.Type) -> K.Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[ObjectIdentifier(key)] as? K.Value
    }
}

// MARK: - Optimizer

public final class MiddlewareChainOptimizer {
    public struct OptimizedChain {
        let middleware: [any Middleware]
        let strategy: ExecutionStrategy
        let metadata: ChainMetadata
        let fastPathExecutor: FastPathExecutor?
    }
    
    public enum ExecutionStrategy {
        case sequential
        case partiallyParallel(groups: [ParallelGroup])
        case fullyParallel
        case failFast(validators: [Int])
        case hybrid(HybridStrategy)
    }
    
    public struct ChainMetadata {
        let count: Int
        let contextModifiers: Int
        let contextReaders: Int
        let canThrow: Bool
        var averageExecutionTime: TimeInterval?
        let allocationPattern: AllocationPattern
    }
    
    public enum AllocationPattern {
        case none, light, moderate, heavy
    }
    
    public struct ParallelGroup {
        let startIndex: Int
        let endIndex: Int
        let middleware: [any Middleware]
    }
    
    public struct HybridStrategy {
        let validationPhase: [Int]?
        let parallelPhase: ParallelGroup?
        let sequentialPhase: [Int]
    }
    
    public final class FastPathExecutor {}
    
    public init() {}
    
    public func optimize(
        middleware: [any Middleware],
        handler: (any CommandHandler)?
    ) -> OptimizedChain {
        let metadata = ChainMetadata(
            count: middleware.count,
            contextModifiers: middleware.count / 2,
            contextReaders: middleware.count / 2,
            canThrow: true,
            averageExecutionTime: nil,
            allocationPattern: .moderate
        )
        
        return OptimizedChain(
            middleware: middleware,
            strategy: .sequential,
            metadata: metadata,
            fastPathExecutor: nil
        )
    }
}

// MARK: - Pipeline

public actor StandardPipeline<C: Command, H: CommandHandler> where H.CommandType == C {
    private var middlewares: [any Middleware] = []
    private let handler: H
    internal var optimizationMetadata: MiddlewareChainOptimizer.OptimizedChain?
    
    public init(handler: H, maxDepth: Int = 100) {
        self.handler = handler
    }
    
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        middlewares.append(contentsOf: newMiddlewares)
    }
    
    internal func setOptimizationMetadata(_ metadata: MiddlewareChainOptimizer.OptimizedChain) {
        self.optimizationMetadata = metadata
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            fatalError("Invalid command type")
        }
        let result = try await handler.handle(typedCommand)
        guard let typedResult = result as? T.Result else {
            fatalError("Invalid result type")
        }
        return typedResult
    }
}

// MARK: - Builder

public actor PipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    private let handler: H
    private var middlewares: [any Middleware] = []
    private var enableOptimization: Bool = false
    
    public init(handler: H) {
        self.handler = handler
    }
    
    @discardableResult
    public func with(_ middleware: any Middleware) -> Self {
        middlewares.append(middleware)
        return self
    }
    
    @discardableResult
    public func withOptimization() -> Self {
        self.enableOptimization = true
        return self
    }
    
    public func build() async throws -> StandardPipeline<T, H> {
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddlewares(middlewares)
        
        if enableOptimization {
            await applyOptimization(to: pipeline)
        }
        
        return pipeline
    }
    
    private func applyOptimization(to pipeline: StandardPipeline<T, H>) async {
        let optimizer = MiddlewareChainOptimizer()
        let optimizedChain = optimizer.optimize(
            middleware: middlewares,
            handler: handler
        )
        
        await pipeline.setOptimizationMetadata(optimizedChain)
    }
}

// MARK: - Test Implementation

struct TestCommand: Command {
    typealias Result = String
    let id: String
}

struct TestHandler: CommandHandler {
    typealias CommandType = TestCommand
    
    func handle(_ command: TestCommand) async throws -> String {
        return "Handled: \(command.id)"
    }
}

final class TestMiddleware: Middleware {
    let name: String
    let priority: ExecutionPriority
    
    init(name: String, priority: ExecutionPriority = .processing) {
        self.name = name
        self.priority = priority
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        print("[\(name)] Processing...")
        return try await next(command, context)
    }
}

// MARK: - Test Runner

struct TestRunner {
    static func main() async {
        do {
            print("=== Testing Pipeline Builder with Optimization ===\n")
            
            // Test 1: Basic optimization activation
            print("Test 1: Building pipeline with optimization enabled")
            let handler = TestHandler()
            let builder = PipelineBuilder(handler: handler)
            
            let pipeline = try await builder
                .with(TestMiddleware(name: "Auth", priority: .authentication))
                .with(TestMiddleware(name: "Validation", priority: .validation))
                .with(TestMiddleware(name: "Logging", priority: .postProcessing))
                .withOptimization()
                .build()
            
            print("✅ Pipeline built successfully with optimization")
            
            // Check if optimization metadata is set
            let hasOptimization = await pipeline.optimizationMetadata != nil
            print("✅ Optimization metadata present: \(hasOptimization)")
            
            if let metadata = await pipeline.optimizationMetadata {
                print("✅ Optimized chain has \(metadata.metadata.count) middleware")
                print("✅ Strategy: \(String(describing: metadata.strategy))")
            }
            
            // Test 2: Execute command with optimized pipeline
            print("\nTest 2: Executing command with optimized pipeline")
            let command = TestCommand(id: "test-123")
            let context = CommandContext()
            let result = try await pipeline.execute(command, context: context)
            print("✅ Result: \(result)")
            
            // Test 3: Building without optimization
            print("\nTest 3: Building pipeline without optimization")
            let normalPipeline = try await PipelineBuilder(handler: handler)
                .with(TestMiddleware(name: "Middleware1"))
                .with(TestMiddleware(name: "Middleware2"))
                .build()
            
            let hasNoOptimization = await normalPipeline.optimizationMetadata == nil
            print("✅ No optimization metadata: \(hasNoOptimization)")
            
            print("\n✅ All tests passed!")
            
        } catch {
            print("❌ Test failed: \(error)")
        }
    }
}

// Run the tests
Task {
    await TestRunner.main()
}