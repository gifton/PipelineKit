import Foundation
import PipelineKit

/// Middleware that validates commands before execution.
/// 
/// This middleware automatically validates any command by calling its
/// validate() method, providing a security layer that ensures
/// only valid data is processed.
/// 
/// Example:
/// ```swift
/// let pipeline = DynamicPipeline()
/// await pipeline.addMiddleware(ValidationMiddleware())
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
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // All commands now have validate() as a protocol requirement
        // with a default implementation that does nothing
        do {
            try command.validate()
        } catch {
            // Re-throw the validation error
            throw error
        }
        
        // Continue to next middleware/handler
        return try await next(command, context)
    }
}
