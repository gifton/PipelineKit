import Foundation
import PipelineKit

/// Mock command processor for testing command transformation
public actor MockCommandProcessor {
    private var processedCommands: [String] = []
    private let processingDelay: TimeInterval
    private let shouldFail: Bool
    
    public init(
        processingDelay: TimeInterval = 0,
        shouldFail: Bool = false
    ) {
        self.processingDelay = processingDelay
        self.shouldFail = shouldFail
    }
    
    public func process<T: Command>(_ command: T) async throws -> T {
        let delayNanoseconds = try testDelayNanoseconds(processingDelay)
        // Record processing
        processedCommands.append(String(describing: type(of: command)))
        
        // Simulate processing delay
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        
        // Simulate failure if configured
        if shouldFail {
            throw MockProcessingError.processingFailed
        }
        
        // Return the command unchanged (in real scenarios, might transform it)
        return command
    }
    
    public func getProcessedCommands() -> [String] {
        processedCommands
    }
    
    public func reset() {
        processedCommands.removeAll()
    }
}

public enum MockProcessingError: LocalizedError, Sendable {
    case processingFailed
    
    public var errorDescription: String? {
        switch self {
        case .processingFailed:
            return "Mock processing failed"
        }
    }
}

// Note: MockBatchProcessor was removed as it relied on creating arbitrary Result types
// which isn't possible with Swift's type system. Tests should use concrete command types
// with known result types instead.
