//
//  CommandContext+Events.swift
//  PipelineKit
//
//  Extends CommandContext with event emission capabilities
//

import Foundation
import PipelineKitCore

// MARK: - Event Emission

public extension CommandContext {
    /// The event emitter for this context
    var eventEmitter: EventEmitter? {
        get { self.get(ContextKeys.eventEmitter) }
    }
    
    /// Sets the event emitter for this context
    func setEventEmitter(_ emitter: EventEmitter?) {
        self.set(ContextKeys.eventEmitter, value: emitter)
    }

    /// Emits an event through the context's event emitter.
    ///
    /// This method is now async due to actor isolation. If no emitter is set,
    /// the event is silently discarded.
    ///
    /// - Parameters:
    ///   - name: The event name
    ///   - properties: Additional event properties
    func emitEvent(_ name: String, properties: [String: any Sendable] = [:]) async {
        guard let emitter = eventEmitter else { return }

        let correlationId = await correlationID ?? commandMetadata.correlationId ?? commandMetadata.id.uuidString
        let event = PipelineEvent(
            name: name,
            properties: properties,
            correlationID: correlationId
        )

        await emitter.emit(event)
    }

    /// Emits a command started event.
    ///
    /// - Parameters:
    ///   - commandType: The type name of the command
    ///   - properties: Additional properties
    func emitCommandStarted(type commandType: String, properties: [String: any Sendable] = [:]) async {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString

        if let userId = await userID {
            props["userID"] = userId
        }

        await emitEvent(PipelineEvent.Name.commandStarted, properties: props)
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
    ) async {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString

        if let duration = duration {
            props["duration"] = duration
        } else if let startTime = await startTime {
            props["duration"] = Date().timeIntervalSince(startTime)
        }

        await emitEvent(PipelineEvent.Name.commandCompleted, properties: props)
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
    ) async {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString
        props["errorType"] = String(describing: type(of: error))
        props["errorMessage"] = error.localizedDescription

        if let startTime = await startTime {
            props["duration"] = Date().timeIntervalSince(startTime)
        }

        await emitEvent(PipelineEvent.Name.commandFailed, properties: props)
    }

    // Note: emitMiddlewareEvent is now defined in PipelineKitCore/Context/CommandContext+Events.swift
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
    ) async -> CommandContext {
        let context = CommandContext(metadata: metadata ?? DefaultCommandMetadata())
        await context.setEventEmitter(emitter)
        return context
    }

    /// Returns a copy of this context with the specified emitter.
    ///
    /// - Parameter emitter: The event emitter to set
    /// - Returns: A new context with the emitter configured
    func withEmitter(_ emitter: EventEmitter) async -> CommandContext {
        let newContext = await self.fork()
        await newContext.setEventEmitter(emitter)
        return newContext
    }
}
