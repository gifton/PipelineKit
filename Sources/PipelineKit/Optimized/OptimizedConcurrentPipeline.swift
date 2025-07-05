import Foundation
import Atomics

/// Optimized concurrent pipeline with reduced actor contention
public struct OptimizedConcurrentPipeline: Pipeline {
    private let shards: [PipelineShard]
    private let shardCount: Int
    private let semaphore: BackPressureAsyncSemaphore
    
    public init(
        options: PipelineOptions = PipelineOptions(),
        shardCount: Int = 16
    ) {
        self.shardCount = shardCount
        self.shards = (0..<shardCount).map { _ in PipelineShard() }
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: options.maxConcurrency ?? 10,
            maxOutstanding: options.maxOutstanding,
            maxQueueMemory: options.maxQueueMemory,
            strategy: options.backPressureStrategy
        )
    }
    
    /// Register a pipeline with sharding based on command type
    public func register<T: Command>(_ commandType: T.Type, pipeline: any Pipeline) async {
        let shard = selectShard(for: commandType)
        await shards[shard].register(commandType, pipeline: pipeline)
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        let shard = selectShard(for: T.self)
        
        // Try fast path first (no await)
        if let pipeline = await shards[shard].getPipeline(for: T.self) {
            let token = try await semaphore.acquire()
            defer { _ = token }
            
            return try await pipeline.execute(command, context: context)
        }
        
        throw PipelineError(
            underlyingError: NoPipelineRegisteredError(commandType: String(describing: T.self)),
            command: command
        )
    }
    
    private func selectShard<T: Command>(for commandType: T.Type) -> Int {
        let typeId = ObjectIdentifier(commandType)
        return abs(typeId.hashValue) % shardCount
    }
}

/// Individual shard for pipeline storage
actor PipelineShard {
    private var pipelines: [ObjectIdentifier: any Pipeline] = [:]
    private let cache = PipelineCache() // Non-async cache for fast lookups
    
    func register<T: Command>(_ commandType: T.Type, pipeline: any Pipeline) {
        let key = ObjectIdentifier(commandType)
        pipelines[key] = pipeline
        cache.set(key, pipeline: pipeline)
    }
    
    func getPipeline<T: Command>(for commandType: T.Type) -> (any Pipeline)? {
        let key = ObjectIdentifier(commandType)
        
        // Try cache first (no async needed)
        if let cached = cache.get(key) {
            return cached
        }
        
        // Fall back to main storage
        return pipelines[key]
    }
}

/// Non-async cache for hot path optimization
final class PipelineCache: @unchecked Sendable {
    private var cache: [ObjectIdentifier: any Pipeline] = [:]
    private let lock = NSLock()
    
    func set(_ key: ObjectIdentifier, pipeline: any Pipeline) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = pipeline
    }
    
    func get(_ key: ObjectIdentifier) -> (any Pipeline)? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }
}

private struct NoPipelineRegisteredError: LocalizedError {
    let commandType: String
    
    var errorDescription: String? {
        "No pipeline registered for command type: \(commandType)"
    }
}