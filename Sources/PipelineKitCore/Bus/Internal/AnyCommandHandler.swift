import Foundation

/// Type-erased wrapper for command handlers.
/// 
/// This internal type allows the CommandBus to store handlers of different types
/// in a single collection while maintaining type safety at the point of use.
/// 
/// The type erasure pattern is necessary because Swift doesn't allow storing
/// protocol types with associated types directly in collections.
struct AnyCommandHandler<T: Command>: Sendable {
    private let _handle: @Sendable (T) async throws -> T.Result
    
    /// Creates a type-erased wrapper for a command handler.
    /// 
    /// - Parameter handler: The concrete handler to wrap
    init<H: CommandHandler>(_ handler: H) where H.CommandType == T {
        self._handle = { command in
            try await handler.handle(command)
        }
    }
    
    /// Handles a command by delegating to the wrapped handler.
    /// 
    /// - Parameter command: The command to handle
    /// - Returns: The result of handling the command
    /// - Throws: Any error thrown by the wrapped handler
    func handle(_ command: T) async throws -> T.Result {
        try await _handle(command)
    }
}
