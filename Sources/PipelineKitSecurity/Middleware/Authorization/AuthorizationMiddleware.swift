import Foundation
import PipelineKitCore

/// Authorization middleware with role-based access control.
public struct AuthorizationMiddleware: Middleware {
    public let priority: ExecutionPriority = .validation
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
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // If no roles are required, allow access (public endpoint)
        if requiredRoles.isEmpty {
            return try await next(command, context)
        }
        
        // Get authenticated user from context
        let metadata = await context.getMetadata()
        guard let userId = metadata["authUserId"] as? String else {
            throw PipelineError.authorization(reason: .invalidCredentials)
        }

        let userRoles = try await getUserRoles(userId)
        await context.setMetadata("authRoles", value: userRoles)

        // Check if user has all required roles
        guard requiredRoles.isSubset(of: userRoles) else {
            throw PipelineError.authorization(reason: .insufficientPermissions(
                required: Array(requiredRoles),
                actual: Array(userRoles)
            ))
        }

        return try await next(command, context)
    }
}
