import Foundation

/// A builder for constructing CommandBus instances with a fluent API.
public actor CommandBusBuilder {
    private var bus: CommandBus

    public init() {
        self.bus = CommandBus()
    }

    public func withCircuitBreaker(_ circuitBreaker: CircuitBreaker) -> Self {
        self.bus = CommandBus(circuitBreaker: circuitBreaker)
        return self
    }

    @discardableResult
    public func with<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async throws -> Self where H.CommandType == T {
        try await bus.register(commandType, handler: handler)
        return self
    }

    @discardableResult
    public func withMiddleware(_ middleware: any Middleware) async throws -> Self {
        try await bus.addMiddleware(middleware)
        return self
    }

    public func build() -> CommandBus {
        return bus
    }
}
