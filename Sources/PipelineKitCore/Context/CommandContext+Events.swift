import Foundation

/// Extension to add core event emission capabilities to CommandContext.
///
/// This provides the foundation for event emission in PipelineKit. 
/// The actual emitter can be set using the eventEmitter context key.
public extension CommandContext {
    /// Gets the event emitter for this context.
    var eventEmitter: EventEmitter? {
        get async {
            self.get(ContextKeys.eventEmitter)
        }
    }
    
    /// Sets the event emitter for this context.
    /// - Parameter emitter: The event emitter to use for this context
    func setEventEmitter(_ emitter: EventEmitter?) async {
        self.set(ContextKeys.eventEmitter, value: emitter)
    }
    
    /// Emits a pipeline event through the configured event emitter.
    ///
    /// If no emitter is configured, the event is silently discarded.
    /// This allows event emission to be optional without requiring
    /// conditional checks at every emission site.
    ///
    /// - Parameter event: The event to emit
    func emitEvent(_ event: PipelineEvent) async {
        // Forward to the configured emitter if present
        if let emitter = await eventEmitter {
            await emitter.emit(event)
        }
        // No fallback to metadata storage - clean separation of concerns
    }
    
    /// Convenience method to emit a middleware event.
    func emitMiddlewareEvent(
        _ name: String,
        middleware: String,
        properties: [String: any Sendable] = [:]
    ) async {
        // Use request ID as correlation ID, or generate one
        let correlationID = getRequestID() ?? UUID().uuidString
        let event = PipelineEvent(
            name: name,
            properties: properties.merging(["middleware": middleware]) { _, new in new },
            correlationID: correlationID
        )
        await emitEvent(event)
    }
    
    /// Convenience method to emit a middleware event with typed properties.
    func emitMiddlewareEvent<T: Sendable>(
        _ name: String,
        middleware: String,
        properties: [String: T]
    ) async {
        // Use request ID as correlation ID, or generate one
        let correlationID = getRequestID() ?? UUID().uuidString
        // Convert typed properties to Any Sendable
        var allProperties: [String: any Sendable] = properties
        allProperties["middleware"] = middleware
        let event = PipelineEvent(
            name: name,
            properties: allProperties,
            correlationID: correlationID
        )
        await emitEvent(event)
    }
}
