import Foundation

/// Authorization middleware with role-based access control.
/// 
/// This middleware should be added with `ExecutionPriority.authorization` priority
/// to ensure it runs after authentication but before business logic.
/// 
/// Example:
/// ```swift
/// let authzMiddleware = AuthorizationMiddleware(requiredRoles: ["admin", "user"])
/// try await pipeline.addMiddleware(authzMiddleware, priority: ExecutionPriority.authorization.rawValue)
/// ```
public struct AuthorizationMiddleware: Middleware {
    private let requiredRoles: Set<String>
    private let roleExtractor: @Sendable (CommandMetadata) async -> Set<String>
    
    /// Creates authorization middleware with required roles.
    /// 
    /// - Parameters:
    ///   - requiredRoles: Set of roles where at least one must be present
    ///   - roleExtractor: Function to extract user roles from metadata
    public init(
        requiredRoles: Set<String>,
        roleExtractor: @escaping @Sendable (CommandMetadata) async -> Set<String>
    ) {
        self.requiredRoles = requiredRoles
        self.roleExtractor = roleExtractor
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        let userRoles = await roleExtractor(metadata)
        
        guard !requiredRoles.isDisjoint(with: userRoles) else {
            throw AuthorizationError.insufficientPermissions
        }
        
        return try await next(command, metadata)
    }
    
    /// Recommended middleware order for this component
    public static var recommendedOrder: ExecutionPriority { .authorization }
}