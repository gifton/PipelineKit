import Foundation

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

// MARK: - Observer Registry

/// A registry for managing multiple pipeline observers
public final class ObserverRegistry: Sendable {
    private let observers: [PipelineObserver]
    
    public init(observers: [PipelineObserver] = []) {
        self.observers = observers
    }
    
    public func notifyPipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.pipelineWillExecute(command, metadata: metadata, pipelineType: pipelineType)
                }
            }
        }
    }
    
    public func notifyPipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.pipelineDidExecute(command, result: result, metadata: metadata, pipelineType: pipelineType, duration: duration)
                }
            }
        }
    }
    
    public func notifyPipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.pipelineDidFail(command, error: error, metadata: metadata, pipelineType: pipelineType, duration: duration)
                }
            }
        }
    }
    
    // Additional notification methods for other events...
    public func notifyMiddlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.middlewareWillExecute(middlewareName, order: order, correlationId: correlationId)
                }
            }
        }
    }
    
    public func notifyMiddlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.middlewareDidExecute(middlewareName, order: order, correlationId: correlationId, duration: duration)
                }
            }
        }
    }
    
    public func notifyMiddlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.middlewareDidFail(middlewareName, order: order, correlationId: correlationId, error: error, duration: duration)
                }
            }
        }
    }
    
    public func notifyHandlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.handlerWillExecute(command, handlerType: handlerType, correlationId: correlationId)
                }
            }
        }
    }
    
    public func notifyHandlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.handlerDidExecute(command, result: result, handlerType: handlerType, correlationId: correlationId, duration: duration)
                }
            }
        }
    }
    
    public func notifyHandlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.handlerDidFail(command, error: error, handlerType: handlerType, correlationId: correlationId, duration: duration)
                }
            }
        }
    }
    
    public func notifyCustomEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        await withTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    await observer.customEvent(eventName, properties: properties, correlationId: correlationId)
                }
            }
        }
    }
}