import Foundation

/// A builder for constructing CommandBus instances with a fluent API.
/// 
/// The builder pattern provides a convenient way to configure a command bus
/// with multiple handlers and middleware in a readable, chainable syntax.
/// Actor isolation ensures thread-safe building even when accessed concurrently.
/// 
/// Example:
/// ```swift
/// let bus = await CommandBusBuilder()
///     .with(CreateUserCommand.self, handler: CreateUserHandler())
///     .with(UpdateUserCommand.self, handler: UpdateUserHandler())
///     .withMiddleware(AuthenticationMiddleware())
///     .withMiddleware(LoggingMiddleware())
///     .build()
/// ```
public actor CommandBusBuilder {
    private let bus: CommandBus
    
    /// Creates a new command bus builder.
    public init() {
        self.bus = CommandBus()
    }
    
    /// Registers a handler for a specific command type.
    /// 
    /// - Parameters:
    ///   - commandType: The type of command to handle
    ///   - handler: The handler instance that will process commands of this type
    /// - Returns: The builder instance for method chaining
    @discardableResult
    public func with<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async throws -> Self where H.CommandType == T {
        try await bus.register(commandType, handler: handler)
        return self
    }
    
    /// Adds a middleware to the command bus pipeline.
    /// 
    /// - Parameter middleware: The middleware to add
    /// - Returns: The builder instance for method chaining
    @discardableResult
    public func withMiddleware(_ middleware: any Middleware) async throws -> Self {
        try await bus.addMiddleware(middleware)
        return self
    }
    
    /// Builds and returns the configured command bus.
    /// 
    /// - Returns: The configured CommandBus instance
    public func build() -> CommandBus {
        return bus
    }
}