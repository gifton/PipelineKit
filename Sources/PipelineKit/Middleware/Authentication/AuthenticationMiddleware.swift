import Foundation

/// Example authentication middleware using context.
public struct AuthenticationMiddleware: Middleware {
    public let priority: ExecutionPriority = .authentication
    private let authenticate: @Sendable (String?) async throws -> String

    public init(authenticate: @escaping @Sendable (String?) async throws -> String) {
        self.authenticate = authenticate
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let metadata = context.commandMetadata
        let userId = try await authenticate(metadata.userId)

        // Store authenticated user in context
        context.set(userId, for: AuthenticatedUserKey.self)

        return try await next(command, context)
    }
}
