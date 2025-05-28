import Foundation

/// Example authorization middleware using context.
public struct ContextAuthorizationMiddleware: ContextAwareMiddleware {
    private let requiredRoles: Set<String>
    private let getUserRoles: @Sendable (String) async throws -> Set<String>
    
    public init(
        requiredRoles: Set<String>,
        getUserRoles: @escaping @Sendable (String) async throws -> Set<String>
    ) {
        self.requiredRoles = requiredRoles
        self.getUserRoles = getUserRoles
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Get authenticated user from context
        guard let userId = await context[AuthenticatedUserKey.self] else {
            throw AuthorizationError.notAuthenticated
        }
        
        let userRoles = try await getUserRoles(userId)
        await context.set(userRoles, for: AuthorizationRolesKey.self)
        
        // Check if user has required roles
        guard !requiredRoles.isDisjoint(with: userRoles) else {
            throw AuthorizationError.insufficientPermissions
        }
        
        return try await next(command, context)
    }
}