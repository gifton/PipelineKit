import Foundation
import PipelineKitCore

/// Middleware that handles authentication for command execution.
///
/// This middleware verifies user identity before allowing command execution.
/// It extracts user credentials from the command metadata, validates them,
/// and stores the authenticated user information in the context for use
/// by subsequent middleware and handlers.
///
/// ## Overview
///
/// The authentication middleware:
/// - Extracts user ID from command metadata
/// - Validates credentials using the provided authentication function
/// - Stores authenticated user information in the context
/// - Prevents unauthorized command execution
///
/// ## Usage
///
/// ```swift
/// let authMiddleware = AuthenticationMiddleware { userId in
///     // Validate user credentials
///     guard let userId = userId else {
///         throw AuthenticationError.missingCredentials
///     }
///     
///     // Verify user exists and is active
///     let user = try await userService.verify(userId)
///     guard user.isActive else {
///         throw AuthenticationError.userInactive
///     }
///     
///     return user.id
/// }
///
/// let pipeline = StandardPipeline(
///     handler: handler,
///     middleware: [authMiddleware, ...]
/// )
/// ```
///
/// ## Context Keys
///
/// The middleware stores the authenticated user ID using `ContextKeys.AuthUserID`.
/// Subsequent middleware and handlers can access it:
///
/// ```swift
/// if let userId = context[ContextKeys.AuthUserID.self] {
///     // Use authenticated user ID
/// }
/// ```
///
/// - Note: This middleware has `.authentication` priority, ensuring it runs
///   before authorization and business logic middleware.
///
/// - SeeAlso: `AuthenticationError`, `ContextKeys.AuthUserID`, `Middleware`
public struct AuthenticationMiddleware: Middleware {
    /// Priority ensures authentication happens early in the pipeline.
    public let priority: ExecutionPriority = .authentication
    
    /// The authentication function that validates user credentials.
    private let authenticate: @Sendable (String?) async throws -> String

    /// Creates a new authentication middleware.
    ///
    /// - Parameter authenticate: An async function that validates user credentials.
    ///   It receives an optional user ID and returns the validated user ID.
    ///   Should throw `AuthenticationError` for authentication failures.
    public init(authenticate: @escaping @Sendable (String?) async throws -> String) {
        self.authenticate = authenticate
    }

    /// Executes authentication before passing the command down the chain.
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context
    ///   - next: The next handler in the chain
    ///
    /// - Returns: The result from the command execution chain
    ///
    /// - Throws: `AuthenticationError` if authentication fails, or any error
    ///   from the downstream chain
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let metadata = context.commandMetadata
        let userId = try await authenticate(metadata.userId)

        // Store authenticated user in context
        context.set(userId, for: ContextKeys.AuthUserID.self)

        return try await next(command, context)
    }
}
