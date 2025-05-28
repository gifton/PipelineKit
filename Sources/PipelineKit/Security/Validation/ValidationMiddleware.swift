import Foundation

/// Middleware that validates commands before execution.
/// 
/// This middleware automatically validates any command that conforms to
/// ValidatableCommand protocol, providing a security layer that ensures
/// only valid data is processed.
/// 
/// Example:
/// ```swift
/// let bus = CommandBus()
/// await bus.addMiddleware(ValidationMiddleware())
/// ```
/// 
/// For proper security, use with priority ordering:
/// ```swift
/// let pipeline = PriorityPipeline(handler: handler)
/// try await pipeline.addMiddleware(
///     ValidationMiddleware(),
///     priority: ExecutionPriority.validation.rawValue
/// )
/// ```
public struct ValidationMiddleware: Middleware {
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if command is validatable
        if let validatableCommand = command as? any ValidatableCommand {
            try validatableCommand.validate()
        }
        
        // Continue to next middleware/handler
        return try await next(command, metadata)
    }
}

// Extension to make ValidationMiddleware an PrioritizedMiddleware
extension ValidationMiddleware: PrioritizedMiddleware {
    /// Recommended middleware order for this component
    public static var recommendedOrder: ExecutionPriority { .validation }
}