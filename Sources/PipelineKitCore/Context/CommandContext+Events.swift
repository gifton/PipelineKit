import Foundation

/// Extension to add event emission capabilities to CommandContext.
extension CommandContext {
    /// Storage key for event observers
    private static let observersKey = "pipeline.event.observers"
    
    /// Adds an event observer to this context.
    public func addObserver(_ observer: any PipelineObserver) async {
        // Since we can't store observers directly (not Sendable), 
        // we'll need to use a different approach
        // For now, we'll skip observer storage and just emit events
    }
    
    /// Removes all event observers.
    public func clearObservers() async {
        // No-op for now
    }
    
    /// Emits a pipeline event to all registered observers.
    public func emitEvent(_ event: PipelineEvent) async {
        // For now, just store the event in metadata for testing/debugging
       setMetadata("last.event", value: event.name)
       setMetadata("last.event.correlationID", value: event.correlationID)
       setMetadata("last.event.sequenceID", value: event.sequenceID)
    }
    
    /// Convenience method to emit a middleware event.
    public func emitMiddlewareEvent(
        _ name: String,
        middleware: String,
        properties: [String: any Sendable] = [:]
    ) async {
        // Use request ID as correlation ID, or generate one
        let correlationID = (getRequestID()) ?? UUID().uuidString
        let event = PipelineEvent(
            name: name,
            properties: properties.merging(["middleware": middleware]) { _, new in new },
            correlationID: correlationID
        )
        await emitEvent(event)
    }
    
    /// Convenience method to emit a middleware event with typed properties.
    public func emitMiddlewareEvent<T: Sendable>(
        _ name: String,
        middleware: String,
        properties: [String: T]
    ) async {
        // Use request ID as correlation ID, or generate one
        let correlationID = (await getRequestID()) ?? UUID().uuidString
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
