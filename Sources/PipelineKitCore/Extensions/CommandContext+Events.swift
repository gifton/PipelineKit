//
//  CommandContext+Events.swift
//  PipelineKit
//
//  Extends CommandContext with event emission capabilities
//

import Foundation

// MARK: - Event Emission

public extension CommandContext {
    /// The event emitter for this context
    var eventEmitter: EventEmitter? {
        get { self[ContextKeys.eventEmitter] }
        set { self[ContextKeys.eventEmitter] = newValue }
    }

    /// Emits an event through the context's event emitter.
    ///
    /// This method is synchronous and non-blocking. If no emitter is set,
    /// the event is silently discarded.
    ///
    /// - Parameters:
    ///   - name: The event name
    ///   - properties: Additional event properties
    func emitEvent(_ name: String, properties: [String: any Sendable] = [:]) {
        guard let emitter = eventEmitter else { return }

        let event = PipelineEvent(
            name: name,
            properties: properties,
            correlationID: correlationID ?? commandMetadata.correlationId ?? commandMetadata.id.uuidString
        )

        emitter.emit(event)
    }

    /// Emits a command started event.
    ///
    /// - Parameters:
    ///   - commandType: The type name of the command
    ///   - properties: Additional properties
    func emitCommandStarted(type commandType: String, properties: [String: any Sendable] = [:]) {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString

        if let userId = userID {
            props["userID"] = userId
        }

        emitEvent(PipelineEvent.Name.commandStarted, properties: props)
    }

    /// Emits a command completed event.
    ///
    /// - Parameters:
    ///   - commandType: The type name of the command
    ///   - duration: Execution duration in seconds
    ///   - properties: Additional properties
    func emitCommandCompleted(
        type commandType: String,
        duration: TimeInterval? = nil,
        properties: [String: any Sendable] = [:]
    ) {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString

        if let duration = duration {
            props["duration"] = duration
        } else if let startTime = startTime {
            props["duration"] = Date().timeIntervalSince(startTime)
        }

        emitEvent(PipelineEvent.Name.commandCompleted, properties: props)
    }

    /// Emits a command failed event.
    ///
    /// - Parameters:
    ///   - commandType: The type name of the command
    ///   - error: The error that occurred
    ///   - properties: Additional properties
    func emitCommandFailed(
        type commandType: String,
        error: Error,
        properties: [String: any Sendable] = [:]
    ) {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString
        props["errorType"] = String(describing: type(of: error))
        props["errorMessage"] = error.localizedDescription

        if let startTime = startTime {
            props["duration"] = Date().timeIntervalSince(startTime)
        }

        emitEvent(PipelineEvent.Name.commandFailed, properties: props)
    }

    /// Emits a middleware event.
    ///
    /// - Parameters:
    ///   - name: The event name (use PipelineEvent.Name constants)
    ///   - middleware: The middleware type name
    ///   - properties: Additional properties
    func emitMiddlewareEvent(
        _ name: String,
        middleware: String,
        properties: [String: any Sendable] = [:]
    ) {
        var props = properties
        props["middleware"] = middleware
        props["commandID"] = commandMetadata.id.uuidString

        emitEvent(name, properties: props)
    }
}

// MARK: - Context Keys

public extension ContextKeys {
    /// Key for storing the event emitter in context
    static let eventEmitter = ContextKey<EventEmitter>("eventEmitter")
}

// MARK: - Builder Pattern Support

public extension CommandContext {
    /// Creates a new context with an event emitter configured.
    ///
    /// - Parameters:
    ///   - emitter: The event emitter to use
    ///   - metadata: Optional command metadata
    /// - Returns: A configured command context
    static func withEmitter(
        _ emitter: EventEmitter,
        metadata: CommandMetadata? = nil
    ) -> CommandContext {
        let context = CommandContext(metadata: metadata ?? DefaultCommandMetadata())
        context.eventEmitter = emitter
        return context
    }

    /// Returns a copy of this context with the specified emitter.
    ///
    /// - Parameter emitter: The event emitter to set
    /// - Returns: A new context with the emitter configured
    func withEmitter(_ emitter: EventEmitter) -> CommandContext {
        let newContext = self.fork()
        newContext.eventEmitter = emitter
        return newContext
    }
}
