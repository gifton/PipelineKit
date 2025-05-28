import Foundation

/// Middleware that sanitizes commands before execution.
/// 
/// This middleware automatically sanitizes any command that conforms to
/// SanitizableCommand protocol, providing a security layer that cleans
/// potentially dangerous input data.
/// 
/// Example:
/// ```swift
/// let bus = CommandBus()
/// await bus.addMiddleware(SanitizationMiddleware())
/// ```
/// 
/// For proper security, use with priority ordering:
/// ```swift
/// let pipeline = PriorityPipeline(handler: handler)
/// try await pipeline.addMiddleware(
///     SanitizationMiddleware(),
///     priority: ExecutionPriority.sanitization.rawValue
/// )
/// ```
public struct SanitizationMiddleware: Middleware {
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if command is sanitizable and create a sanitized copy
        if let sanitizableCommand = command as? any SanitizableCommand {
            let sanitized = sanitizableCommand.sanitized()
            
            // Safely cast back to T
            guard let sanitizedCommand = sanitized as? T else {
                // This should never happen in practice, but handle it gracefully
                return try await next(command, metadata)
            }
            
            return try await next(sanitizedCommand, metadata)
        }
        
        // Continue with original command if not sanitizable
        return try await next(command, metadata)
    }
}

// Extension to make SanitizationMiddleware an PrioritizedMiddleware
extension SanitizationMiddleware: PrioritizedMiddleware {
    /// Recommended middleware order for this component
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .sanitization }
}