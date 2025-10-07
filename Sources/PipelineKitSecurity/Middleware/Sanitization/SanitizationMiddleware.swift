import Foundation
import PipelineKit

/// Middleware that sanitizes commands before execution.
/// 
/// This middleware automatically sanitizes any command by calling its
/// sanitize() method, providing a security layer that cleans
/// potentially dangerous input data such as:
/// - HTML/JavaScript injection attempts
/// - SQL injection patterns  
/// - Path traversal sequences
/// - Control characters
/// - Excessive whitespace
/// 
/// ## What Sanitization Does
/// 
/// The default sanitization (via Command extension) returns the command unchanged.
/// Commands that need sanitization should override the `sanitize()` method to:
/// - Strip or escape HTML tags
/// - Remove script content
/// - Normalize Unicode characters
/// - Trim excessive whitespace
/// - Validate and clean file paths
/// 
/// ## Usage Examples
/// 
/// ```swift
/// // Basic usage with standard pipeline
/// let pipeline = StandardPipeline(
///     handler: handler,
///     middleware: [
///         SanitizationMiddleware(),
///         AuthenticationMiddleware(...),
///         // other middleware
///     ]
/// )
/// 
/// // Custom command with sanitization
/// struct CreatePostCommand: Command {
///     let title: String
///     let content: String
///     
///     func sanitize() throws -> Self {
///         CreatePostCommand(
///             title: title.trimmingCharacters(in: .whitespacesAndNewlines)
///                          .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
///             content: content.replacingOccurrences(of: "<script[^>]*>.*?</script>", with: "", options: .regularExpression)
///         )
///     }
/// }
/// ```
/// 
/// ## Security Best Practices
/// 
/// - Place SanitizationMiddleware early in the pipeline (before processing)
/// - Combine with validation middleware for defense in depth
/// - Log sanitization events for security auditing
/// - Consider using allow-lists rather than deny-lists for input validation
public struct SanitizationMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    
    public init() {}
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // All commands now have sanitize() via extension
        // The default implementation returns self, so this is safe
        let sanitized = try command.sanitize()
        
        // Continue with sanitized command
        return try await next(sanitized, context)
    }
}
