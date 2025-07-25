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
/// let pipeline = AnyStandardPipeline(handler: handler)
/// try await pipeline.addMiddleware(
///     ValidationMiddleware(),
///     priority: ExecutionPriority.validation.rawValue
/// )
/// ```
public struct ValidationMiddleware: Middleware {
    public let priority: ExecutionPriority = .validation
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if command is validatable
        if let validatableCommand = command as? any ValidatableCommand {
            try validatableCommand.validate()
        }
        
        // Continue to next middleware/handler
        return try await next(command, context)
    }
}

