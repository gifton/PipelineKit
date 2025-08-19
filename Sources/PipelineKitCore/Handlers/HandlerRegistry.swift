import Foundation

/// A thread-safe registry for command handlers.
///
/// `HandlerRegistry` provides actor-isolated storage and retrieval of command handlers,
/// ensuring all mutations and reads are performed safely in concurrent environments.
/// This eliminates data races when multiple actors or tasks interact with the command bus.
///
/// ## Thread Safety
/// All operations on the registry are performed within actor isolation, guaranteeing:
/// - Safe concurrent registration of handlers
/// - Safe concurrent lookup of handlers
/// - No data races on the internal storage
///
/// ## Example
/// ```swift
/// let registry = HandlerRegistry()
/// 
/// // Register a handler (thread-safe)
/// try await registry.register(CreateUserCommand.self, handler: CreateUserHandler())
/// 
/// // Lookup a handler (thread-safe)
/// if let handler = await registry.handler(for: CreateUserCommand.self) as? AnyCommandHandler<CreateUserCommand> {
///     let result = try await handler.handle(command)
/// }
/// ```
actor HandlerRegistry {
    /// Type-erased storage for handlers indexed by command type.
    /// We store handlers as Any but they are guaranteed to be AnyCommandHandler<T> for some T.
    private var handlers: [ObjectIdentifier: any Sendable] = [:]
    
    /// Registers a handler for a specific command type.
    ///
    /// This method is thread-safe and can be called concurrently from multiple tasks.
    /// If a handler is already registered for the command type, it will be replaced.
    ///
    /// - Parameters:
    ///   - commandType: The type of command this handler processes
    ///   - handler: The handler instance that will process commands of this type
    func register<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async throws where H.CommandType == T {
        let key = ObjectIdentifier(commandType)
        handlers[key] = AnyCommandHandler(handler)
    }
    
    /// Retrieves a handler for a specific command type.
    ///
    /// This method is thread-safe and can be called concurrently from multiple tasks.
    ///
    /// - Parameter commandType: The type of command to find a handler for
    /// - Returns: The registered handler, or `nil` if no handler is registered
    func handler<T: Command>(for commandType: T.Type) async -> (any Sendable)? {
        let key = ObjectIdentifier(commandType)
        return handlers[key]
    }
    
    /// Removes a handler for a specific command type.
    ///
    /// This method is thread-safe and can be called concurrently from multiple tasks.
    ///
    /// - Parameter commandType: The type of command to remove the handler for
    /// - Returns: The removed handler, or `nil` if no handler was registered
    @discardableResult
    func removeHandler<T: Command>(for commandType: T.Type) async -> (any Sendable)? {
        let key = ObjectIdentifier(commandType)
        return handlers.removeValue(forKey: key)
    }
    
    /// Removes all registered handlers.
    ///
    /// This method is thread-safe and can be called concurrently from multiple tasks.
    func removeAllHandlers() async {
        handlers.removeAll()
    }
    
    /// Returns the number of registered handlers.
    ///
    /// This property is thread-safe and can be accessed concurrently from multiple tasks.
    var count: Int {
        handlers.count
    }
    
    /// Returns whether a handler is registered for a specific command type.
    ///
    /// This method is thread-safe and can be called concurrently from multiple tasks.
    ///
    /// - Parameter commandType: The command type to check
    /// - Returns: `true` if a handler is registered, `false` otherwise
    func hasHandler<T: Command>(for commandType: T.Type) async -> Bool {
        let key = ObjectIdentifier(commandType)
        return handlers[key] != nil
    }
    
    /// Returns all registered command types.
    ///
    /// This property provides insight into what commands the registry can handle.
    /// The returned strings are debug representations of the ObjectIdentifiers.
    ///
    /// This property is thread-safe and can be accessed concurrently from multiple tasks.
    var registeredCommandTypes: [String] {
        handlers.keys.map { key in
            // ObjectIdentifier debug description includes type information
            String(describing: key)
        }
    }
}
