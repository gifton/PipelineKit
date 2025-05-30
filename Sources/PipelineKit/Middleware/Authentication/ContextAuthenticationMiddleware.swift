import Foundation

/// Example authentication middleware using context.
public struct ContextAuthenticationMiddleware: ContextAwareMiddleware {
    private let authenticate: @Sendable (String?) async throws -> String
    
    public init(authenticate: @escaping @Sendable (String?) async throws -> String) {
        self.authenticate = authenticate
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let metadata = await context.commandMetadata
        let userId = try await authenticate(metadata.userId)
        
        // Store authenticated user in context
        await context.set(userId, for: AuthenticatedUserKey.self)
        
        return try await next(command, context)
    }
}