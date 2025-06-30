import Foundation

// Example demonstrating the unified Pipeline macro supporting all pipeline types
// The @Pipeline macro now generates context-based API code

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

// Example 2: Context-aware pipeline (now maps to StandardPipeline)
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

/// Example usage function showing both macro-generated and manual pipeline creation
public func runUnifiedMacroExamples() async throws {
    let command = UnifiedMacroCommand(value: "test")
    let context = CommandContext(metadata: StandardCommandMetadata())
    
    // Example 1: Using macro-generated standard pipeline
    let standardService = StandardPipelineService()
    let result1 = try await standardService.execute(command, context: context)
    print("Standard pipeline (macro): \(result1)")
    
    // Example 2: Using macro-generated context-aware pipeline (now StandardPipeline)
    let contextAwareService = ContextAwarePipelineService()
    let result2 = try await contextAwareService.execute(command, context: context)
    print("Context-aware pipeline (macro): \(result2)")
    
    // Example 3: Using macro-generated concurrent pipeline
    let concurrentService = ConcurrentStandardService()
    let result3 = try await concurrentService.execute(command, context: context)
    print("Concurrent pipeline (macro): \(result3)")
    
    // Manual pipeline creation for comparison
    let handler = UnifiedMacroHandler()
    let manualPipeline = StandardPipeline(handler: handler)
    let manualResult = try await manualPipeline.execute(command, context: context)
    print("Manual pipeline: \(manualResult)")
    
    print("\nAll pipeline macro examples completed successfully!")
}
