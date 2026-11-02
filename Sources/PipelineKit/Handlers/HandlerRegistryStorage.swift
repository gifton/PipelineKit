import PipelineKitCore

/// Synchronous handler storage owned by its containing actor.
struct HandlerRegistryStorage {
    // Both insertion paths store AnyCommandHandler<T> under ObjectIdentifier(T.self).
    private var handlers: [ObjectIdentifier: any Sendable] = [:]

    mutating func insertIfAbsent<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) -> Bool where H.CommandType == T {
        let key = ObjectIdentifier(commandType)
        guard handlers[key] == nil else { return false }
        handlers[key] = AnyCommandHandler(handler)
        return true
    }

    /// Inserts when absent; the result reports whether a previous handler existed.
    @discardableResult
    mutating func replace<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        with handler: H
    ) -> Bool where H.CommandType == T {
        handlers.updateValue(AnyCommandHandler(handler), forKey: ObjectIdentifier(commandType)) != nil
    }

    func handler<T: Command>(for commandType: T.Type) -> AnyCommandHandler<T>? {
        handlers[ObjectIdentifier(commandType)] as? AnyCommandHandler<T>
    }

    @discardableResult
    mutating func removeHandler<T: Command>(for commandType: T.Type) -> AnyCommandHandler<T>? {
        handlers.removeValue(forKey: ObjectIdentifier(commandType)) as? AnyCommandHandler<T>
    }

    mutating func removeAllHandlers() {
        handlers.removeAll()
    }

    var count: Int { handlers.count }

    func hasHandler<T: Command>(for commandType: T.Type) -> Bool {
        handlers[ObjectIdentifier(commandType)] != nil
    }

    var registeredCommandTypes: [String] {
        handlers.keys.map { String(describing: $0) }
    }
}
