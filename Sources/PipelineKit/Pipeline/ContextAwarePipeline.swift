import Foundation

/// A pipeline that provides context throughout command execution.
/// 
/// The context-aware pipeline extends the standard pipeline with a shared
/// context that middleware and handlers can use to communicate. This enables
/// sophisticated patterns like:
/// 
/// - Authentication results shared across middleware
/// - Performance metrics collection
/// - Request-scoped caching
/// - Dynamic feature flags
/// 
/// Example:
/// ```swift
/// let pipeline = ContextAwarePipeline(handler: CreateUserHandler())
/// await pipeline.addMiddleware(AuthenticationMiddleware())
/// await pipeline.addMiddleware(AuthorizationMiddleware())
/// await pipeline.addMiddleware(MetricsMiddleware())
/// 
/// let result = try await pipeline.execute(
///     CreateUserCommand(email: "user@example.com"),
///     metadata: DefaultCommandMetadata(userId: "admin")
/// )
/// ```
public actor ContextAwarePipeline: Pipeline {
    private var middlewares: [any ContextAwareMiddleware] = []
    private let handler: AnyContextHandler
    private let maxDepth: Int
    
    private struct AnyContextHandler: Sendable {
        let execute: @Sendable (Any, CommandContext) async throws -> Any
        
        init<T: Command, H: CommandHandler>(_ handler: H) where H.CommandType == T {
            self.execute = { command, context in
                guard let typedCommand = command as? T else {
                    throw PipelineError.invalidCommandType
                }
                return try await handler.handle(typedCommand)
            }
        }
    }
    
    /// Creates a context-aware pipeline with the given handler.
    /// 
    /// - Parameters:
    ///   - handler: The command handler
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyContextHandler(handler)
        self.maxDepth = maxDepth
    }
    
    /// Adds a context-aware middleware to the pipeline.
    /// 
    /// - Parameter middleware: The middleware to add
    /// - Throws: PipelineError.maxDepthExceeded if limit is reached
    public func addMiddleware(_ middleware: any ContextAwareMiddleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(middleware)
    }
    
    /// Adds a regular middleware to the pipeline by wrapping it.
    /// 
    /// - Parameter middleware: The regular middleware to add
    /// - Throws: PipelineError.maxDepthExceeded if limit is reached
    public func addRegularMiddleware(_ middleware: any Middleware) throws {
        try addMiddleware(ContextMiddlewareAdapter(middleware))
    }
    
    /// Executes a command through the context-aware pipeline.
    /// 
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Command metadata
    /// - Returns: The command result
    /// - Throws: Any errors from middleware or handler
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result {
        let context = CommandContext(metadata: metadata)
        
        // Set initial context values
        await context.set(Date(), for: RequestStartTimeKey.self)
        await context.set(UUID().uuidString, for: RequestIDKey.self)
        
        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            let result = try await self.handler.execute(cmd, ctx)
            guard let typedResult = result as? T.Result else {
                throw PipelineError.invalidResultType
            }
            return typedResult
        }
        
        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: next)
            }
        }
        
        return try await chain(command, context)
    }
    
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    public var middlewareCount: Int {
        middlewares.count
    }
}

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

/// Example metrics middleware using context.
public struct ContextMetricsMiddleware: ContextAwareMiddleware {
    private let recordMetric: @Sendable (String, TimeInterval) async -> Void
    
    public init(recordMetric: @escaping @Sendable (String, TimeInterval) async -> Void) {
        self.recordMetric = recordMetric
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = await context[RequestStartTimeKey.self] ?? Date()
        
        do {
            let result = try await next(command, context)
            
            let duration = Date().timeIntervalSince(startTime)
            await recordMetric(String(describing: T.self), duration)
            
            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            await recordMetric("\(String(describing: T.self)).error", duration)
            throw error
        }
    }
}

public enum AuthorizationError: Error, Sendable, Equatable, Hashable, LocalizedError {
    case notAuthenticated
    case insufficientPermissions
    
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User is not authenticated"
        case .insufficientPermissions:
            return "User does not have sufficient permissions for this operation"
        }
    }
}