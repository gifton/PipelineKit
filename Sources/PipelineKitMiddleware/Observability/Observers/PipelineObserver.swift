import Foundation
import PipelineKitCore

// MARK: - Core Observability Protocols

/// A protocol for observing pipeline execution events
public protocol PipelineObserver: Sendable {
    /// Called when a pipeline starts executing a command
    func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async
    
    /// Called when a pipeline successfully completes executing a command
    func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async
    
    /// Called when a pipeline fails to execute a command
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async
    
    /// Called when middleware starts executing
    func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async
    
    /// Called when middleware completes successfully
    func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async
    
    /// Called when middleware fails
    func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async
    
    /// Called when a command handler starts executing
    func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async
    
    /// Called when a command handler completes successfully
    func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async
    
    /// Called when a command handler fails
    func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async
    
    /// Called for custom events that can be emitted from middleware or handlers
    func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async
}


// MARK: - Observable Event Types

/// Represents different types of observable events in the pipeline
public enum ObservableEvent: Sendable {
    case pipelineStarted(PipelineStartedEvent)
    case pipelineCompleted(PipelineCompletedEvent)
    case pipelineFailed(PipelineFailedEvent)
    case middlewareStarted(MiddlewareStartedEvent)
    case middlewareCompleted(MiddlewareCompletedEvent)
    case middlewareFailed(MiddlewareFailedEvent)
    case handlerStarted(HandlerStartedEvent)
    case handlerCompleted(HandlerCompletedEvent)
    case handlerFailed(HandlerFailedEvent)
    case customEvent(CustomEvent)
}

// MARK: - Event Data Structures

public struct PipelineStartedEvent: Sendable {
    public let commandType: String
    public let pipelineType: String
    public let correlationId: String
    public let timestamp: Date
    public let metadata: [String: String]
    
    public init(commandType: String, pipelineType: String, correlationId: String, timestamp: Date = Date(), metadata: [String: String] = [:]) {
        self.commandType = commandType
        self.pipelineType = pipelineType
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

public struct PipelineCompletedEvent: Sendable {
    public let commandType: String
    public let pipelineType: String
    public let correlationId: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let resultType: String
    public let metadata: [String: String]
    
    public init(commandType: String, pipelineType: String, correlationId: String, timestamp: Date = Date(), duration: TimeInterval, resultType: String, metadata: [String: String] = [:]) {
        self.commandType = commandType
        self.pipelineType = pipelineType
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.duration = duration
        self.resultType = resultType
        self.metadata = metadata
    }
}

public struct PipelineFailedEvent: Sendable {
    public let commandType: String
    public let pipelineType: String
    public let correlationId: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let error: String
    public let errorType: String
    public let metadata: [String: String]
    
    public init(commandType: String, pipelineType: String, correlationId: String, timestamp: Date = Date(), duration: TimeInterval, error: String, errorType: String, metadata: [String: String] = [:]) {
        self.commandType = commandType
        self.pipelineType = pipelineType
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.duration = duration
        self.error = error
        self.errorType = errorType
        self.metadata = metadata
    }
}

public struct MiddlewareStartedEvent: Sendable {
    public let middlewareName: String
    public let order: Int
    public let correlationId: String
    public let timestamp: Date
    
    public init(middlewareName: String, order: Int, correlationId: String, timestamp: Date = Date()) {
        self.middlewareName = middlewareName
        self.order = order
        self.correlationId = correlationId
        self.timestamp = timestamp
    }
}

public struct MiddlewareCompletedEvent: Sendable {
    public let middlewareName: String
    public let order: Int
    public let correlationId: String
    public let timestamp: Date
    public let duration: TimeInterval
    
    public init(middlewareName: String, order: Int, correlationId: String, timestamp: Date = Date(), duration: TimeInterval) {
        self.middlewareName = middlewareName
        self.order = order
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.duration = duration
    }
}

public struct MiddlewareFailedEvent: Sendable {
    public let middlewareName: String
    public let order: Int
    public let correlationId: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let error: String
    public let errorType: String
    
    public init(middlewareName: String, order: Int, correlationId: String, timestamp: Date = Date(), duration: TimeInterval, error: String, errorType: String) {
        self.middlewareName = middlewareName
        self.order = order
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.duration = duration
        self.error = error
        self.errorType = errorType
    }
}

public struct HandlerStartedEvent: Sendable {
    public let commandType: String
    public let handlerType: String
    public let correlationId: String
    public let timestamp: Date
    
    public init(commandType: String, handlerType: String, correlationId: String, timestamp: Date = Date()) {
        self.commandType = commandType
        self.handlerType = handlerType
        self.correlationId = correlationId
        self.timestamp = timestamp
    }
}

public struct HandlerCompletedEvent: Sendable {
    public let commandType: String
    public let handlerType: String
    public let correlationId: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let resultType: String
    
    public init(commandType: String, handlerType: String, correlationId: String, timestamp: Date = Date(), duration: TimeInterval, resultType: String) {
        self.commandType = commandType
        self.handlerType = handlerType
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.duration = duration
        self.resultType = resultType
    }
}

public struct HandlerFailedEvent: Sendable {
    public let commandType: String
    public let handlerType: String
    public let correlationId: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let error: String
    public let errorType: String
    
    public init(commandType: String, handlerType: String, correlationId: String, timestamp: Date = Date(), duration: TimeInterval, error: String, errorType: String) {
        self.commandType = commandType
        self.handlerType = handlerType
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.duration = duration
        self.error = error
        self.errorType = errorType
    }
}

public struct CustomEvent: Sendable {
    public let eventName: String
    public let correlationId: String
    public let timestamp: Date
    public let properties: [String: String]
    
    public init(eventName: String, correlationId: String, timestamp: Date = Date(), properties: [String: String] = [:]) {
        self.eventName = eventName
        self.correlationId = correlationId
        self.timestamp = timestamp
        self.properties = properties
    }
}

// MARK: - Default Observer Implementation

/// A no-op observer that can be extended for specific implementations
///
/// This class contains no mutable state and is safe to use across concurrent contexts.
/// Subclasses must ensure they maintain thread safety.
///
/// ## Design Decision: @unchecked Sendable for Base Class
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Subclass Flexibility**: As an open class designed for subclassing, Swift cannot
///    verify that all possible subclasses will be thread-safe at compile time.
///
/// 2. **No Stored Properties**: BaseObserver itself has no stored properties, making it
///    inherently thread-safe. The empty implementation ensures no shared mutable state.
///
/// 3. **Protocol Conformance**: PipelineObserver protocol requires Sendable, and this
///    base class provides a safe foundation that delegates thread-safety responsibility
///    to concrete implementations.
///
/// 4. **Safe by Design**: All methods have empty default implementations that do nothing,
///    eliminating any possibility of data races at the base class level.
///
/// Subclasses must maintain their own thread safety by:
/// - Using only Sendable stored properties
/// - Synchronizing access to any mutable state
/// - Avoiding shared mutable references
open class BaseObserver: PipelineObserver, @unchecked Sendable {
    public init() {}
    
    open func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        // Default implementation does nothing
    }
    
    open func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        // Default implementation does nothing
    }
    
    open func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        // Default implementation does nothing
    }
    
    open func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        // Default implementation does nothing
    }
    
    open func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        // Default implementation does nothing
    }
    
    open func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        // Default implementation does nothing
    }
    
    open func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        // Default implementation does nothing
    }
    
    open func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        // Default implementation does nothing
    }
    
    open func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        // Default implementation does nothing
    }
    
    open func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        // Default implementation does nothing
    }
}

// MARK: - Observer Failure Tracking

/// Detailed information about an observer notification failure.
public struct ObserverFailure: Sendable {
    /// The type name of the observer that failed.
    public let observerType: String
    
    /// The event name that was being processed when the failure occurred.
    public let eventName: String
    
    /// The error that caused the failure.
    public let error: Error
    
    /// When the failure occurred.
    public let timestamp: Date
    
    /// Additional context about the failure (e.g., command type, correlation ID).
    public let additionalContext: String?
}

// MARK: - Observer Registry

/// A registry for managing multiple pipeline observers with guaranteed thread safety.
///
/// Actor isolation ensures that observer notifications are properly coordinated
/// and prevents race conditions during observer management.
public actor ObserverRegistry {
    private var observers: [PipelineObserver]
    
    /// Error handler for observer failures - can be customized for different logging systems.
    private let errorHandler: @Sendable (ObserverFailure) -> Void
    
    /// Creates a new observer registry with optional custom error handling.
    ///
    /// - Parameters:
    ///   - observers: Initial observers to register
    ///   - errorHandler: Custom error handler for observer failures (defaults to console logging)
    public init(
        observers: [PipelineObserver] = [],
        errorHandler: (@Sendable (ObserverFailure) -> Void)? = nil
    ) {
        self.observers = observers
        self.errorHandler = errorHandler ?? ObserverRegistry.defaultErrorHandler
    }
    
    /// Adds an observer to the registry.
    public func addObserver(_ observer: PipelineObserver) {
        observers.append(observer)
    }
    
    /// Removes observers of the specified type.
    public func removeObserver<T: PipelineObserver>(ofType type: T.Type) {
        observers.removeAll { observer in
            Swift.type(of: observer) == type
        }
    }
    
    /// Gets the current number of registered observers.
    public var observerCount: Int {
        observers.count
    }
    
    /// Default error handler that logs to console with detailed context.
    private static let defaultErrorHandler: @Sendable (ObserverFailure) -> Void = { failure in
        let timestamp = ISO8601DateFormatter().string(from: failure.timestamp)
        
        print("""
        ⚠️ Observer Notification Failed
        ├─ Time: \(timestamp)
        ├─ Observer: \(failure.observerType)
        ├─ Event: \(failure.eventName)
        ├─ Error: \(failure.error.localizedDescription)
        └─ Details: \(failure.additionalContext ?? "None")
        """)
        
        #if DEBUG
        // In debug builds, also print the full error for debugging
        print("   Debug info: \(failure.error)")
        #endif
    }
    
    /// Safely executes an observer notification with detailed error handling.
    private func safelyNotify(
        observer: PipelineObserver,
        eventName: String,
        additionalContext: String? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            let failure = ObserverFailure(
                observerType: String(describing: type(of: observer)),
                eventName: eventName,
                error: error,
                timestamp: Date(),
                additionalContext: additionalContext
            )
            errorHandler(failure)
        }
    }
    
    /// Safely notifies all observers with detailed error tracking.
    private func notifyObservers(
        eventName: String,
        additionalContext: String? = nil,
        operation: @escaping @Sendable (PipelineObserver) async throws -> Void
    ) async {
        for observer in observers {
            await safelyNotify(
                observer: observer,
                eventName: eventName,
                additionalContext: additionalContext,
                operation: { try await operation(observer) }
            )
        }
    }
    
    public func notifyPipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        await notifyObservers(
            eventName: "pipelineWillExecute",
            additionalContext: "Command: \(String(describing: T.self)), Pipeline: \(pipelineType), CorrelationId: \(metadata.correlationId ?? "none")"
        ) { observer in
            await observer.pipelineWillExecute(command, metadata: metadata, pipelineType: pipelineType)
        }
    }
    
    public func notifyPipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await notifyObservers(
            eventName: "pipelineDidExecute",
            additionalContext: "Command: \(String(describing: T.self)), Pipeline: \(pipelineType), Duration: \(duration)s, CorrelationId: \(metadata.correlationId ?? "none")"
        ) { observer in
            await observer.pipelineDidExecute(command, result: result, metadata: metadata, pipelineType: pipelineType, duration: duration)
        }
    }
    
    public func notifyPipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await notifyObservers(
            eventName: "pipelineDidFail",
            additionalContext: "Command: \(String(describing: T.self)), Pipeline: \(pipelineType), Duration: \(duration)s, Error: \(error.localizedDescription), CorrelationId: \(metadata.correlationId ?? "none")"
        ) { observer in
            await observer.pipelineDidFail(command, error: error, metadata: metadata, pipelineType: pipelineType, duration: duration)
        }
    }
    
    // Additional notification methods for other events...
    public func notifyMiddlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        await notifyObservers(
            eventName: "middlewareWillExecute",
            additionalContext: "Middleware: \(middlewareName), Order: \(order), CorrelationId: \(correlationId)"
        ) { observer in
            await observer.middlewareWillExecute(middlewareName, order: order, correlationId: correlationId)
        }
    }
    
    public func notifyMiddlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        await notifyObservers(
            eventName: "middlewareDidExecute",
            additionalContext: "Middleware: \(middlewareName), Order: \(order), Duration: \(duration)s, CorrelationId: \(correlationId)"
        ) { observer in
            await observer.middlewareDidExecute(middlewareName, order: order, correlationId: correlationId, duration: duration)
        }
    }
    
    public func notifyMiddlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        await notifyObservers(
            eventName: "middlewareDidFail",
            additionalContext: "Middleware: \(middlewareName), Order: \(order), Duration: \(duration)s, Error: \(error.localizedDescription), CorrelationId: \(correlationId)"
        ) { observer in
            await observer.middlewareDidFail(middlewareName, order: order, correlationId: correlationId, error: error, duration: duration)
        }
    }
    
    public func notifyHandlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        await notifyObservers(
            eventName: "handlerWillExecute",
            additionalContext: "Command: \(String(describing: T.self)), Handler: \(handlerType), CorrelationId: \(correlationId)"
        ) { observer in
            await observer.handlerWillExecute(command, handlerType: handlerType, correlationId: correlationId)
        }
    }
    
    public func notifyHandlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await notifyObservers(
            eventName: "handlerDidExecute",
            additionalContext: "Command: \(String(describing: T.self)), Handler: \(handlerType), Duration: \(duration)s, CorrelationId: \(correlationId)"
        ) { observer in
            await observer.handlerDidExecute(command, result: result, handlerType: handlerType, correlationId: correlationId, duration: duration)
        }
    }
    
    public func notifyHandlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await notifyObservers(
            eventName: "handlerDidFail",
            additionalContext: "Command: \(String(describing: T.self)), Handler: \(handlerType), Duration: \(duration)s, Error: \(error.localizedDescription), CorrelationId: \(correlationId)"
        ) { observer in
            await observer.handlerDidFail(command, error: error, handlerType: handlerType, correlationId: correlationId, duration: duration)
        }
    }
    
    public func notifyCustomEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        await notifyObservers(
            eventName: "customEvent: \(eventName)",
            additionalContext: "Event: \(eventName), Properties: \(properties.count) items, CorrelationId: \(correlationId)"
        ) { observer in
            await observer.customEvent(eventName, properties: properties, correlationId: correlationId)
        }
    }
}
