import Foundation
import PipelineKitCore

/// Middleware that sanitizes commands before execution.
/// 
/// This middleware automatically sanitizes any command by calling its
/// sanitize() method, providing a security layer that cleans
/// potentially dangerous input data.
/// 
/// Example:
/// ```swift
/// let pipeline = DynamicPipeline()
/// await pipeline.addMiddleware(SanitizationMiddleware())
/// ```
/// 
/// For proper security, use with priority ordering:
/// ```swift
/// let pipeline = AnyStandardPipeline(handler: handler)
/// try await pipeline.addMiddleware(
///     SanitizationMiddleware(),
///     priority: ExecutionPriority.preProcessing.rawValue
/// )
/// ```
public struct SanitizationMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // All commands now have sanitize() via extension
        // The default implementation returns self, so this is safe
        let sanitized = try command.sanitize()
        
        // Continue with sanitized command
        return try await next(sanitized, context)
    }
}
