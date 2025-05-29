import Foundation

// Example demonstrating the unified Pipeline macro supporting all pipeline types

// Test command and handler
public struct UnifiedMacroCommand: Command {
    public typealias Result = String
    public let value: String
    
    public init(value: String) {
        self.value = value
    }
}

public struct UnifiedMacroHandler: CommandHandler {
    public typealias CommandType = UnifiedMacroCommand
    
    public init() {}
    
    public func handle(_ command: UnifiedMacroCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

// Example 1: Standard pipeline (default behavior)
@Pipeline
public actor StandardPipelineService {
    public typealias CommandType = UnifiedMacroCommand
    public let handler = UnifiedMacroHandler()
    
    public init() {}
}

// Example 2: Context-aware pipeline
@Pipeline(context: .enabled)
public actor ContextAwarePipelineService {
    public typealias CommandType = UnifiedMacroCommand
    public let handler = UnifiedMacroHandler()
    
    public init() {}
}

// Example 3: Standard pipeline with concurrency limits
@Pipeline(concurrency: .limited(5))
public actor ConcurrentStandardService {
    public typealias CommandType = UnifiedMacroCommand
    public let handler = UnifiedMacroHandler()
    
    public init() {}
}

/// Example usage function
public func runUnifiedMacroExamples() async throws {
    let command = UnifiedMacroCommand(value: "test")
    let metadata = DefaultCommandMetadata()
    
    // Test standard pipeline
    let standardService = StandardPipelineService()
    let result1 = try await standardService.execute(command, metadata: metadata)
    print("Standard: \(result1)")
    
    // Test context-aware pipeline
    let contextService = ContextAwarePipelineService()
    let result2 = try await contextService.execute(command, metadata: metadata)
    print("Context-aware: \(result2)")
    
    // Test concurrent standard
    let concurrentService = ConcurrentStandardService()
    let result3 = try await concurrentService.execute(command, metadata: metadata)
    print("Concurrent: \(result3)")
    
    print("Basic unified macro examples completed successfully!")
}