import Foundation

/// A protocol that defines cross-cutting functionality in the command pipeline.
///
/// Middleware components intercept command execution to provide features like
/// authentication, validation, logging, caching, and error handling. They form
/// a chain of responsibility where each middleware can process the command before
/// and/or after passing it to the next component in the chain.
///
/// ## Overview
///
/// Middleware follows the chain of responsibility pattern, where each middleware:
/// - Receives a command and context
/// - Can modify the context or validate the command
/// - Decides whether to pass execution to the next middleware
/// - Can process the result after the chain completes
///
/// ## Execution Order
///
/// Middleware execution order is determined by the `priority` property. The pipeline
/// sorts middleware by priority before building the execution chain. Standard priorities
/// include:
/// - `.authentication` (1000): Verify user identity
/// - `.authorization` (900): Check permissions
/// - `.validation` (800): Validate command data
/// - `.preProcessing` (500): Transform or enrich data
/// - `.postProcessing` (100): Process results
/// - `.custom` (0): Default priority
///
/// ## Thread Safety
///
/// All middleware must be `Sendable` to ensure thread safety in concurrent environments.
/// Avoid storing mutable state in middleware instances.
///
/// ## Example
///
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     let priority = ExecutionPriority.postProcessing
///
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         let start = Date()
///         do {
///             let result = try await next(command, context)
///             print("Command \(T.self) succeeded in \(Date().timeIntervalSince(start))s")
///             return result
///         } catch {
///             print("Command \(T.self) failed: \(error)")
///             throw error
///         }
///     }
/// }
/// ```
///
/// - SeeAlso: `ExecutionPriority`, `Pipeline`, `Command`
public protocol Middleware: Sendable {
    /// The priority of the middleware, which determines its execution order.
    ///
    /// Higher priority values execute first. Use predefined priorities from
    /// `ExecutionPriority` or create custom values.
    var priority: ExecutionPriority { get }

    /// Executes the middleware logic for a command.
    ///
    /// This method receives a command and can:
    /// - Validate or transform the command
    /// - Modify the context
    /// - Call the next middleware in the chain
    /// - Process the result
    /// - Handle errors
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context containing metadata and shared data
    ///   - next: The next handler in the chain (middleware or final handler)
    ///
    /// - Returns: The result of command execution
    ///
    /// - Throws: Any error that occurs during execution. Middleware can catch
    ///   and handle errors from the chain, or propagate them up.
    ///
    /// - Note: Always call `next` unless you intentionally want to short-circuit
    ///   the pipeline (e.g., for caching or authorization failures).
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

// MARK: - Middleware Typealiases

/// Typealias for the middleware next closure.
///
/// This type alias simplifies middleware signatures by providing a shorter,
/// more readable name for the continuation function that invokes the next
/// middleware in the chain or the final command handler.
///
/// ## Usage
///
/// Instead of writing the full closure signature:
/// ```swift
/// next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
/// ```
///
/// You can use the more concise form:
/// ```swift
/// next: @escaping MiddlewareNext<T>
/// ```
///
/// Both forms are completely equivalent and fully compatible. The typealias
/// is purely for improved readability and maintainability.
///
/// ## Example
///
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>  // ✅ Cleaner signature
///     ) async throws -> T.Result {
///         print("Executing: \(T.self)")
///         return try await next(command, context)
///     }
/// }
/// ```
///
/// ## Before and After
///
/// **Before:**
/// ```swift
/// func execute<T: Command>(
///     _ command: T,
///     context: CommandContext,
///     next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
/// ) async throws -> T.Result
/// ```
///
/// **After:**
/// ```swift
/// func execute<T: Command>(
///     _ command: T,
///     context: CommandContext,
///     next: @escaping MiddlewareNext<T>
/// ) async throws -> T.Result
/// ```
///
/// - Note: This typealias is compile-time only and has zero runtime overhead.
///
/// - SeeAlso: `Middleware`
public typealias MiddlewareNext<T: Command> = @Sendable (T, CommandContext) async throws -> T.Result

// Add extension for default priority
public extension Middleware {
    /// Default priority for middleware when not specified.
    ///
    /// - Note: Custom middleware should explicitly set priority when order matters.
    var priority: ExecutionPriority { .custom }
}

/// A marker protocol for middleware that opt out of automatic NextGuard safety.
///
/// ## WARNING: Use at Your Own Risk
///
/// Conforming to this protocol disables the automatic NextGuard wrapper that ensures
/// `next` is called exactly once. You become fully responsible for:
/// - Ensuring `next` is called exactly once (unless explicitly short-circuiting)
/// - Managing the lifecycle of the `next` closure if stored
/// - Preventing memory leaks from retain cycles
/// - Avoiding duplicated side effects from multiple calls
///
/// ## When to Use
///
/// Only conform to `UnsafeMiddleware` when you need to:
/// - Implement custom retry/replay logic
/// - Build performance-critical middleware with guaranteed single execution
/// - Create testing/debugging middleware that intentionally calls next multiple times
/// - Provide your own safety mechanisms
///
/// ## Example
///
/// ```swift
/// struct CustomRetryMiddleware: Middleware, UnsafeMiddleware {
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         // Custom logic that might call next multiple times
///         var lastError: Error?
///         for attempt in 1...3 {
///             do {
///                 return try await next(command, context)
///             } catch {
///                 lastError = error
///                 if attempt < 3 {
///                     try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
///                 }
///             }
///         }
///         throw lastError ?? PipelineError.retryExhausted(attempts: 3, lastError: nil)
///     }
/// }
/// ```
///
/// - Warning: Violations of the exactly-once guarantee can corrupt the pipeline state,
///   cause memory leaks, undefined behavior, or duplicated side effects.
///
/// - SeeAlso: `Middleware`, `NextGuard`
public protocol UnsafeMiddleware: Middleware {
    // Marker protocol - no additional requirements
}

/// A marker protocol for middleware that want to suppress NextGuard deinit warnings.
///
/// Conform when middleware may intentionally not call `next` under normal,
/// non-error conditions and the lack of a call should not surface as a debug warning
/// (for example, caching or fast-path short-circuiting). This affects only debug
/// deinit warnings; it does not change NextGuard's runtime safety checks.
public protocol NextGuardWarningSuppressing: Middleware {
    // Marker protocol - no additional requirements
}

// MARK: - Conditional Middleware

/// A protocol for middleware that can conditionally activate based on command or context.
///
/// Conform to `ConditionalMiddleware` when your middleware should only execute
/// under certain conditions, such as:
/// - Feature flags being enabled
/// - Specific context values being present
/// - Command conforming to certain marker protocols
/// - Runtime configuration settings
///
/// ## Overview
///
/// By default, all middleware executes for every command. `ConditionalMiddleware`
/// adds a `shouldActivate` method that the pipeline checks before invoking the
/// middleware. If `shouldActivate` returns `false`, the middleware is bypassed
/// entirely and the next component in the chain is called directly.
///
/// ## Performance
///
/// The `shouldActivate` check is performed at the start of each execution. For
/// maximum performance, the check should be as lightweight as possible—ideally
/// just reading a boolean from context or checking a type conformance.
///
/// ## Example: Feature-Flagged Middleware
///
/// ```swift
/// struct EncryptionMiddleware: ConditionalMiddleware {
///     let priority = ExecutionPriority.preProcessing
///
///     func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
///         // Only activate if encryption is enabled in feature flags
///         return context[\.featureFlags]?.encryptionEnabled ?? false
///     }
///
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         // Encryption logic here
///         let result = try await next(command, context)
///         return result
///     }
/// }
/// ```
///
/// ## Example: Type-Based Activation
///
/// ```swift
/// protocol RequiresAudit: Command {}
///
/// struct AuditMiddleware: ConditionalMiddleware {
///     func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
///         // Only audit commands that opt-in
///         return command is any RequiresAudit
///     }
///
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         let result = try await next(command, context)
///         await auditLog.record(command: command, result: result)
///         return result
///     }
/// }
/// ```
///
/// - Note: If `shouldActivate` returns `false`, the middleware's `execute` method
///   is never called, and the command passes directly to the next component.
///
/// - SeeAlso: `Middleware`, `ScopedMiddleware`
public protocol ConditionalMiddleware: Middleware {
    /// Determines whether this middleware should activate for a given command.
    ///
    /// Called before `execute` for each command. If this returns `false`, the
    /// middleware is bypassed and the next component in the chain is called directly.
    ///
    /// - Parameters:
    ///   - command: The command about to be executed
    ///   - context: The command context containing metadata and shared data
    ///
    /// - Returns: `true` if the middleware should execute, `false` to bypass
    ///
    /// - Note: This method should be lightweight and fast. Avoid I/O operations
    ///   or expensive computations—instead, rely on cached values or type checks.
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool
}

/// Default implementation that always activates.
public extension ConditionalMiddleware {
    /// By default, conditional middleware always activates.
    ///
    /// Override this method to implement custom activation logic.
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
        return true
    }
}

// MARK: - Scoped Middleware (Marker Protocol Pattern)

/// A protocol for middleware that only activates for commands conforming to a marker protocol.
///
/// `ScopedMiddleware` builds on `ConditionalMiddleware` to provide a cleaner pattern
/// for type-based middleware scoping. Instead of manually checking command types in
/// `shouldActivate`, you specify a `Scope` marker protocol and the middleware
/// automatically activates only for commands that conform to it.
///
/// ## Overview
///
/// This pattern allows you to declare middleware requirements at the command level
/// using marker protocols. Commands "opt-in" to middleware by conforming to the
/// appropriate marker protocol.
///
/// ## Defining a Scope
///
/// First, define a marker protocol for your scope:
///
/// ```swift
/// /// Marker protocol for commands that require encryption
/// protocol RequiresEncryption: Command {}
///
/// /// Marker protocol for commands that should be audited
/// protocol Auditable: Command {}
/// ```
///
/// ## Implementing Scoped Middleware
///
/// ```swift
/// struct EncryptionMiddleware: ScopedMiddleware {
///     // Only commands conforming to RequiresEncryption will trigger this middleware
///     typealias Scope = RequiresEncryption
///
///     let priority = ExecutionPriority.preProcessing
///
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @escaping MiddlewareNext<T>
///     ) async throws -> T.Result {
///         // This code only runs for RequiresEncryption commands
///         // The command can be safely cast: command as! RequiresEncryption
///         let result = try await next(command, context)
///         return encryptResult(result)
///     }
/// }
/// ```
///
/// ## Using Marker Protocols on Commands
///
/// ```swift
/// // This command triggers EncryptionMiddleware
/// struct CreateEntryCommand: Command, RequiresEncryption {
///     typealias Result = Entry
///     let content: String
/// }
///
/// // This command does NOT trigger EncryptionMiddleware
/// struct SearchCommand: Command {
///     typealias Result = [Entry]
///     let query: String
/// }
/// ```
///
/// ## Multiple Scopes
///
/// Commands can conform to multiple marker protocols to trigger multiple middleware:
///
/// ```swift
/// struct UpdateEntryCommand: Command, RequiresEncryption, Auditable {
///     typealias Result = Entry
///     let entryId: UUID
///     let newContent: String
/// }
/// // Both EncryptionMiddleware and AuditMiddleware will activate
/// ```
///
/// ## Performance
///
/// The type conformance check uses Swift's `is` operator which is highly optimized.
/// The check happens once per command execution and is essentially free compared
/// to the actual middleware logic.
///
/// - Note: `ScopedMiddleware` inherits from `ConditionalMiddleware`, so you can
///   still override `shouldActivate` for additional runtime checks if needed.
///
/// - SeeAlso: `ConditionalMiddleware`, `Middleware`
public protocol ScopedMiddleware: ConditionalMiddleware {
    /// The marker protocol that commands must conform to for this middleware to activate.
    ///
    /// Define this as your custom marker protocol that extends `Command`.
    ///
    /// Example:
    /// ```swift
    /// protocol RequiresValidation: Command {}
    ///
    /// struct ValidationMiddleware: ScopedMiddleware {
    ///     typealias Scope = RequiresValidation
    ///     // ...
    /// }
    /// ```
    associatedtype Scope
}

/// Default implementation that checks command conformance to the Scope protocol.
public extension ScopedMiddleware {
    /// Activates only when the command conforms to the `Scope` protocol.
    ///
    /// This implementation uses Swift's `is` operator for efficient type checking.
    /// The check is performed at runtime but is highly optimized by the compiler.
    func shouldActivate<T: Command>(for command: T, context: CommandContext) -> Bool {
        return command is Scope
    }
}

// MARK: - Common Marker Protocols

/// Marker protocol for commands that require encryption.
///
/// Commands conforming to `RequiresEncryption` will automatically trigger
/// any `ScopedMiddleware` that targets this scope.
///
/// ```swift
/// struct CreateSecretCommand: Command, RequiresEncryption {
///     typealias Result = Secret
///     let data: Data
/// }
/// ```
public protocol RequiresEncryption: Command {}

/// Marker protocol for commands that require validation.
///
/// Commands conforming to `RequiresValidation` will automatically trigger
/// any `ScopedMiddleware` that targets this scope.
///
/// ```swift
/// struct CreateUserCommand: Command, RequiresValidation {
///     typealias Result = User
///     let email: String
///     let password: String
/// }
/// ```
public protocol RequiresValidation: Command {}

/// Marker protocol for commands that require authentication.
///
/// Commands conforming to `RequiresAuthentication` will automatically trigger
/// any `ScopedMiddleware` that targets this scope.
///
/// ```swift
/// struct DeleteAccountCommand: Command, RequiresAuthentication {
///     typealias Result = Void
///     let userId: UUID
/// }
/// ```
public protocol RequiresAuthentication: Command {}

/// Marker protocol for commands that should be audited.
///
/// Commands conforming to `Auditable` will automatically trigger
/// any `ScopedMiddleware` that targets this scope.
///
/// ```swift
/// struct TransferFundsCommand: Command, Auditable {
///     typealias Result = TransferReceipt
///     let fromAccount: UUID
///     let toAccount: UUID
///     let amount: Decimal
/// }
/// ```
public protocol Auditable: Command {}

/// Marker protocol for commands that should be cached.
///
/// Commands conforming to `Cacheable` will automatically trigger
/// any `ScopedMiddleware` that targets this scope.
///
/// ```swift
/// struct GetUserProfileCommand: Command, Cacheable {
///     typealias Result = UserProfile
///     let userId: UUID
/// }
/// ```
public protocol Cacheable: Command {}
