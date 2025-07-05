import Foundation
import Atomics

/// Fixed BatchEntry using proper Swift continuations
private struct SafeBatchEntry<C: Command> {
    let id = UUID()
    let command: C
    let context: CommandContext
    let continuation: CheckedContinuation<C.Result, Error>
}

/// Safe batch processor with proper async/await patterns
public actor SafeBatchProcessor<C: Command> {
    public typealias Configuration = BatchProcessor<C>.Configuration
    
    private let pipeline: any Pipeline
    private let configuration: Configuration
    private var pendingBatch: [SafeBatchEntry<C>] = []
    private var batchTimer: Task<Void, Never>?
    private let batchCounter = ManagedAtomic<Int>(0)
    
    public init(pipeline: any Pipeline, configuration: Configuration = Configuration()) {
        self.pipeline = pipeline
        self.configuration = configuration
    }
    
    /// Submit command for batch processing with proper continuation handling
    public func submit(_ command: C, context: CommandContext? = nil) async throws -> C.Result {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.addToBatch(
                    command: command,
                    context: context ?? CommandContext(),
                    continuation: continuation
                )
            }
        }
    }
    
    /// Internal method to handle batch addition
    private func addToBatch(
        command: C,
        context: CommandContext,
        continuation: CheckedContinuation<C.Result, Error>
    ) async {
        let entry = SafeBatchEntry(
            command: command,
            context: context,
            continuation: continuation
        )
        
        pendingBatch.append(entry)
        
        // Check if we should process the batch
        if pendingBatch.count >= configuration.maxBatchSize {
            await processPendingBatch()
        } else if configuration.partialBatchStrategy == .processAfterTimeout && batchTimer == nil {
            startBatchTimer()
        }
    }
    
    /// Submit multiple commands as a batch
    public func submitBatch(_ commands: [C], context: CommandContext? = nil) async throws -> [Result<C.Result, Error>] {
        let batchContext = BatchContext(
            batchId: batchCounter.wrappingIncrementThenLoad(ordering: .relaxed),
            size: commands.count
        )
        
        return await withTaskGroup(of: (Int, Result<C.Result, Error>).self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    do {
                        let ctx = context ?? CommandContext()
                        await ctx.set(batchContext, for: BatchContextKey.self)
                        let result = try await self.pipeline.execute(command, context: ctx)
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            
            var results = Array(repeating: Result<C.Result, Error>.failure(
                PipelineError.internalError("Not executed")
            ), count: commands.count)
            
            for await (index, result) in group {
                results[index] = result
            }
            
            return results
        }
    }
    
    /// Force processing of pending batch
    public func flush() async {
        await processPendingBatch()
    }
    
    private func processPendingBatch() async {
        let entries = pendingBatch
        pendingBatch.removeAll(keepingCapacity: true)
        
        guard !entries.isEmpty else { return }
        
        let batchContext = BatchContext(
            batchId: batchCounter.wrappingIncrementThenLoad(ordering: .relaxed),
            size: entries.count
        )
        
        if configuration.preserveOrder {
            // Process sequentially
            for entry in entries {
                do {
                    await entry.context.set(batchContext, for: BatchContextKey.self)
                    let result = try await pipeline.execute(entry.command, context: entry.context)
                    entry.continuation.resume(returning: result)
                } catch {
                    entry.continuation.resume(throwing: error)
                }
            }
        } else {
            // Process concurrently
            await withTaskGroup(of: Void.self) { group in
                for entry in entries {
                    group.addTask {
                        do {
                            await entry.context.set(batchContext, for: BatchContextKey.self)
                            let result = try await self.pipeline.execute(
                                entry.command,
                                context: entry.context
                            )
                            entry.continuation.resume(returning: result)
                        } catch {
                            entry.continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    private func startBatchTimer() {
        batchTimer?.cancel()
        batchTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(configuration.maxBatchWaitTime * 1_000_000_000))
            
            if !Task.isCancelled {
                await processPendingBatch()
            }
        }
    }
    
    deinit {
        batchTimer?.cancel()
        
        // Ensure all pending continuations are resumed
        for entry in pendingBatch {
            entry.continuation.resume(throwing: CancellationError())
        }
    }
}