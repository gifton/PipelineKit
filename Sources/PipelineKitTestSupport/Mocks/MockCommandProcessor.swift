import Foundation
import PipelineKit

/// Mock command processor for testing command transformation
public final class MockCommandProcessor: @unchecked Sendable {
    private var processedCommands: [String] = []
    private let processingDelay: TimeInterval
    private let shouldFail: Bool
    private let lock = NSLock()
    
    public init(
        processingDelay: TimeInterval = 0,
        shouldFail: Bool = false
    ) {
        self.processingDelay = processingDelay
        self.shouldFail = shouldFail
    }
    
    public func process<T: Command>(_ command: T) async throws -> T {
        // Record processing
        lock.withLock {
            processedCommands.append(String(describing: type(of: command)))
        }
        
        // Simulate processing delay
        if processingDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(processingDelay * 1_000_000_000))
        }
        
        // Simulate failure if configured
        if shouldFail {
            throw MockProcessingError.processingFailed
        }
        
        // Return the command unchanged (in real scenarios, might transform it)
        return command
    }
    
    public func getProcessedCommands() -> [String] {
        lock.withLock { processedCommands }
    }
    
    public func reset() {
        lock.withLock {
            processedCommands.removeAll()
        }
    }
}

public enum MockProcessingError: LocalizedError {
    case processingFailed
    
    public var errorDescription: String? {
        switch self {
        case .processingFailed:
            return "Mock processing failed"
        }
    }
}

/// Mock batch processor for testing batch operations
public final class MockBatchProcessor: @unchecked Sendable {
    private let batchSize: Int
    private var batches: [[String]] = []
    private let lock = NSLock()
    
    public init(batchSize: Int = 10) {
        self.batchSize = batchSize
    }
    
    public func processBatch<T: Command>(_ commands: [T]) async throws -> [T.Result] {
        // Record batch
        lock.withLock {
            batches.append(commands.map { String(describing: type(of: $0)) })
        }
        
        // Process each command (simplified - in real scenario would batch process)
        var results: [T.Result] = []
        for command in commands {
            // Simulate processing by creating a simple result
            // In real implementation, would need proper result creation
            if let handler = MockCommandHandler<T>() as? CommandHandler,
               let typedHandler = handler as? MockCommandHandler<T> {
                let result = try await typedHandler.handle(command)
                results.append(result)
            }
        }
        
        return results
    }
    
    public func getBatches() -> [[String]] {
        lock.withLock { batches }
    }
}

/// Simple mock command handler for testing
private struct MockCommandHandler<T: Command>: CommandHandler {
    typealias CommandType = T
    
    func handle(_ command: T) async throws -> T.Result {
        // This is a limitation - we can't create arbitrary Result types
        // In real tests, you'd use concrete command types with known results
        fatalError("MockCommandHandler requires concrete command types with known results")
    }
}