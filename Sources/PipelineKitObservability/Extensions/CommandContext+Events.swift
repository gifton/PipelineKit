//
//  CommandContext+Events.swift
//  PipelineKit
//
//  Extends CommandContext with additional observability event helpers
//

import Foundation
import PipelineKitCore

// MARK: - Event Emission Helpers

public extension CommandContext {
    /// Emits an event through the context's event emitter with automatic correlation ID.
    ///
    /// This is a convenience wrapper that adds correlation ID handling on top of
    /// the Core event emission functionality.
    ///
    /// - Parameters:
    ///   - name: The event name
    ///   - properties: Additional event properties
    func emitEvent(_ name: String, properties: [String: any Sendable] = [:]) async {
        guard eventEmitter != nil else { return }

        let correlationId = correlationID ?? commandMetadata.correlationID ?? commandMetadata.id.uuidString
        let event = PipelineEvent(
            name: name,
            properties: properties,
            correlationID: correlationId
        )

        await emitEvent(event)
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

        if let userId = userID {
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
        } else if let startTime = startTime {
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
        error: any Error,
        properties: [String: any Sendable] = [:]
    ) async {
        var props = properties
        props["commandType"] = commandType
        props["commandID"] = commandMetadata.id.uuidString
        props["errorType"] = String(describing: type(of: error))
        props["errorMessage"] = error.localizedDescription

        if let startTime = startTime {
            props["duration"] = Date().timeIntervalSince(startTime)
        }

        await emitEvent(PipelineEvent.Name.commandFailed, properties: props)
    }

    // Note: emitMiddlewareEvent is now defined in PipelineKitCore/Context/CommandContext+Events.swift
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
        _ emitter: any EventEmitter,
        metadata: (any CommandMetadata)? = nil
    ) async -> CommandContext {
        let context = CommandContext(metadata: metadata ?? DefaultCommandMetadata())
        context.eventEmitter = emitter
        return context
    }

    /// Returns a copy of this context with the specified emitter.
    ///
    /// - Parameter emitter: The event emitter to set
    /// - Returns: A new context with the emitter configured
    func withEmitter(_ emitter: any EventEmitter) async -> CommandContext {
        let newContext = self.fork()
        newContext.eventEmitter = emitter
        return newContext
    }
}
