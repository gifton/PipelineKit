import Foundation
import Atomics

/// A high-performance batch processor for bulk command execution
/// - Warning: This implementation has unsafe AsyncThrowingContinuation usage. Use SafeBatchProcessor instead.
@available(*, deprecated, renamed: "SafeBatchProcessor", message: "Use SafeBatchProcessor for proper async/await continuation handling")
public actor BatchProcessor<C: Command> {
    /// Configuration for batch processing behavior
    public struct Configuration: Sendable {
        /// Maximum number of commands in a single batch
        public let maxBatchSize: Int
        
        /// Maximum time to wait before processing a partial batch
        public let maxBatchWaitTime: TimeInterval
        
        /// Whether to preserve command ordering within batches
        public let preserveOrder: Bool
        
        /// Strategy for handling partial batches
        public let partialBatchStrategy: PartialBatchStrategy
        
        public init(
            maxBatchSize: Int = 100,
            maxBatchWaitTime: TimeInterval = 0.01, // 10ms
            preserveOrder: Bool = false,
            partialBatchStrategy: PartialBatchStrategy = .processImmediately
        ) {
            self.maxBatchSize = maxBatchSize
            self.maxBatchWaitTime = maxBatchWaitTime
            self.preserveOrder = preserveOrder
            self.partialBatchStrategy = partialBatchStrategy
        }
    }
    
    public enum PartialBatchStrategy: Sendable {
        case waitForFull
        case processImmediately
        case processAfterTimeout
    }
    
    // MARK: - Private Properties
    
    private let pipeline: any Pipeline
    private let configuration: Configuration
    private var pendingBatch: PendingBatch<C> = PendingBatch()
    private var batchTimer: Task<Void, Never>?
    private let batchCounter = ManagedAtomic<Int>(0)
    
    // MARK: - Initialization
    
    public init(pipeline: any Pipeline, configuration: Configuration = Configuration()) {
        self.pipeline = pipeline
        self.configuration = configuration
    }
    
    // MARK: - Public API
    
    /// Submits a command for batch processing
    public func submit(_ command: C, context: CommandContext? = nil) async throws -> C.Result {
        let entry = BatchEntry(command: command, context: context ?? CommandContext())
        
        // Add to pending batch
        pendingBatch.add(entry)
        
        // Check if we should process the batch
        if pendingBatch.count >= configuration.maxBatchSize {
            return try await processBatchAndGetResult(for: entry.id)
        }
        
        // Start timer if needed
        if configuration.partialBatchStrategy == .processAfterTimeout && batchTimer == nil {
            startBatchTimer()
        }
        
        // Wait for result
        return try await entry.resultContinuation.value
    }
    
    /// Submits multiple commands as a pre-formed batch
    public func submitBatch(_ commands: [C], context: CommandContext? = nil) async throws -> [Result<C.Result, Error>] {
        let entries = commands.map { command in
            BatchEntry(command: command, context: context ?? CommandContext())
        }
        
        // Process immediately as a complete batch
        return try await processBatch(entries)
    }
    
    /// Forces processing of any pending commands
    public func flush() async throws {
        if !pendingBatch.isEmpty {
            _ = try await processPendingBatch()
        }
    }
    
    // MARK: - Private Methods
    
    private func processBatchAndGetResult(for entryId: UUID) async throws -> C.Result {
        let entries = pendingBatch.drain()
        let results = try await processBatch(entries)
        
        // Find and return the specific result
        if let index = entries.firstIndex(where: { $0.id == entryId }) {
            switch results[index] {
            case .success(let result):
                return result
            case .failure(let error):
                throw error
            }
        }
        
        throw PipelineError.internalError("Batch entry not found")
    }
    
    private func processBatch(_ entries: [BatchEntry<C>]) async throws -> [Result<C.Result, Error>] {
        let batchId = batchCounter.wrappingIncrementThenLoad(ordering: .relaxed)
        
        // Create batch context
        let batchContext = BatchContext(batchId: batchId, size: entries.count)
        
        // Execute commands with optimized batching
        if configuration.preserveOrder {
            return await processOrderedBatch(entries, batchContext: batchContext)
        } else {
            return await processUnorderedBatch(entries, batchContext: batchContext)
        }
    }
    
    private func processOrderedBatch(
        _ entries: [BatchEntry<C>],
        batchContext: BatchContext
    ) async -> [Result<C.Result, Error>] {
        var results: [Result<C.Result, Error>] = []
        results.reserveCapacity(entries.count)
        
        for entry in entries {
            do {
                // Inject batch context
                await entry.context.set(batchContext, for: BatchContextKey.self)
                
                let result = try await pipeline.execute(entry.command, context: entry.context)
                results.append(.success(result))
                entry.resultContinuation.resume(returning: result)
            } catch {
                results.append(.failure(error))
                entry.resultContinuation.resume(throwing: error)
            }
        }
        
        return results
    }
    
    private func processUnorderedBatch(
        _ entries: [BatchEntry<C>],
        batchContext: BatchContext
    ) async -> [Result<C.Result, Error>] {
        await withTaskGroup(of: (Int, Result<C.Result, Error>).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    do {
                        // Inject batch context
                        await entry.context.set(batchContext, for: BatchContextKey.self)
                        
                        let result = try await self.pipeline.execute(entry.command, context: entry.context)
                        entry.resultContinuation.resume(returning: result)
                        return (index, .success(result))
                    } catch {
                        entry.resultContinuation.resume(throwing: error)
                        return (index, .failure(error))
                    }
                }
            }
            
            var results = Array(repeating: Result<C.Result, Error>.failure(PipelineError.internalError("Not executed")), count: entries.count)
            
            for await (index, result) in group {
                results[index] = result
            }
            
            return results
        }
    }
    
    private func processPendingBatch() async throws {
        let entries = pendingBatch.drain()
        if !entries.isEmpty {
            _ = try await processBatch(entries)
        }
    }
    
    private func startBatchTimer() {
        batchTimer?.cancel()
        batchTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(configuration.maxBatchWaitTime * 1_000_000_000))
            
            if !Task.isCancelled {
                try? await processPendingBatch()
            }
        }
    }
    
    deinit {
        batchTimer?.cancel()
    }
}

// MARK: - Supporting Types

private struct BatchEntry<C: Command> {
    let id = UUID()
    let command: C
    let context: CommandContext
    let resultContinuation: AsyncThrowingContinuation<C.Result>
    
    init(command: C, context: CommandContext) {
        self.command = command
        self.context = context
        self.resultContinuation = AsyncThrowingContinuation<C.Result>()
    }
}

private struct PendingBatch<C: Command> {
    private var entries: [BatchEntry<C>] = []
    
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    
    mutating func add(_ entry: BatchEntry<C>) {
        entries.append(entry)
    }
    
    mutating func drain() -> [BatchEntry<C>] {
        let drained = entries
        entries.removeAll(keepingCapacity: true)
        return drained
    }
}

public struct BatchContext: Sendable {
    public let batchId: Int
    public let size: Int
    public let timestamp = Date()
}

public struct BatchContextKey: ContextKey {
    public typealias Value = BatchContext
}

// MARK: - Async Continuation Helper

private final class AsyncThrowingContinuation<T>: @unchecked Sendable {
    private let _continuation: UnsafeContinuation<T, Error>
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?
    
    init() {
        var storedContinuation: UnsafeContinuation<T, Error>?
        self._continuation = withUnsafeContinuation { continuation in
            storedContinuation = continuation
        }
    }
    
    func resume(returning value: T) {
        result = .success(value)
        semaphore.signal()
    }
    
    func resume(throwing error: Error) {
        result = .failure(error)
        semaphore.signal()
    }
    
    var value: T {
        get async throws {
            await withCheckedThrowingContinuation { continuation in
                Task {
                    semaphore.wait()
                    switch result! {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

// MARK: - Pipeline Error Extension

extension PipelineError {
    static func internalError(_ message: String) -> PipelineError {
        PipelineError(underlyingError: NSError(
            domain: "PipelineKit.Batching",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ), command: nil)
    }
}