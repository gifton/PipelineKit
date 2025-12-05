//
//  PipelineRegistry.swift
//  PipelineKit
//
//  Central registry for managing pipelines.
//

import Foundation
import PipelineKitCore

/// Statistics about the pipeline registry.
public struct RegistryStats: Sendable, Equatable {
    /// Total number of registered pipelines.
    public let pipelineCount: Int

    /// Number of unique command types with registered pipelines.
    public let commandTypeCount: Int

    /// Names of all registered pipelines grouped by command type.
    public let pipelinesByType: [String: [String]]

    /// Timestamp when stats were collected.
    public let timestamp: Date

    public init(
        pipelineCount: Int,
        commandTypeCount: Int,
        pipelinesByType: [String: [String]],
        timestamp: Date = Date()
    ) {
        self.pipelineCount = pipelineCount
        self.commandTypeCount = commandTypeCount
        self.pipelinesByType = pipelinesByType
        self.timestamp = timestamp
    }
}

/// Central registry for managing pipelines across the application.
///
/// `PipelineRegistry` provides a thread-safe, actor-isolated storage for pipelines.
/// It supports multiple pipelines per command type through named registration,
/// and provides introspection capabilities for debugging.
///
/// ## Usage
///
/// ```swift
/// // Create a registry
/// let registry = PipelineRegistry()
///
/// // Register pipelines
/// await registry.register(userPipeline, for: CreateUserCommand.self)
/// await registry.register(orderPipeline, for: ProcessOrderCommand.self, named: "standard")
/// await registry.register(priorityOrderPipeline, for: ProcessOrderCommand.self, named: "priority")
///
/// // Retrieve pipelines
/// let pipeline = await registry.pipeline(for: CreateUserCommand.self)
///
/// // Execute through registry
/// let result = try await registry.execute(CreateUserCommand(name: "John"))
/// ```
///
/// ## Type-Safe Keys
///
/// For compile-time type safety, use `PipelineKey`:
///
/// ```swift
/// extension PipelineKey where T == CreateUserCommand {
///     static let main = PipelineKey("main")
/// }
///
/// await registry.register(pipeline, for: .main)
/// let p = await registry.pipeline(for: PipelineKey<CreateUserCommand>.main)
/// ```
///
/// ## Thread Safety
///
/// All operations are actor-isolated, ensuring thread-safe access from concurrent contexts.
public actor PipelineRegistry {

    // MARK: - Private Types

    /// Internal entry storing pipeline with metadata.
    private struct PipelineEntry: Sendable {
        let pipeline: any Pipeline
        let commandTypeName: String
        let commandTypeID: ObjectIdentifier
        let name: String
        let registeredAt: Date
    }

    // MARK: - Storage

    /// Primary storage: registry key -> PipelineEntry
    private var entries: [String: PipelineEntry] = [:]

    /// Index: command type ID -> [registry keys]
    private var byCommandType: [ObjectIdentifier: Set<String>] = [:]

    // MARK: - Initialization

    /// Creates a new empty pipeline registry.
    public init() {}

    // MARK: - Registration (Type-Safe with PipelineKey)

    /// Registers a pipeline with a type-safe key.
    ///
    /// - Parameters:
    ///   - pipeline: The pipeline to register.
    ///   - key: The type-safe key identifying this pipeline.
    ///
    /// - Note: If a pipeline is already registered with this key, it will be replaced.
    public func register<T: Command>(
        _ pipeline: any Pipeline,
        for key: PipelineKey<T>
    ) {
        let registryKey = key.registryKey
        let typeID = ObjectIdentifier(T.self)

        let entry = PipelineEntry(
            pipeline: pipeline,
            commandTypeName: String(describing: T.self),
            commandTypeID: typeID,
            name: key.name,
            registeredAt: Date()
        )

        // Remove old entry from index if replacing
        if let oldEntry = entries[registryKey] {
            byCommandType[oldEntry.commandTypeID]?.remove(registryKey)
        }

        entries[registryKey] = entry
        byCommandType[typeID, default: []].insert(registryKey)
    }

    /// Registers a pipeline for a command type with an optional name.
    ///
    /// - Parameters:
    ///   - pipeline: The pipeline to register.
    ///   - commandType: The command type this pipeline handles.
    ///   - name: Optional name for the pipeline. Defaults to "default".
    public func register<T: Command>(
        _ pipeline: any Pipeline,
        for commandType: T.Type,
        named name: String = "default"
    ) {
        register(pipeline, for: PipelineKey<T>(name))
    }

    // MARK: - Retrieval (Type-Safe with PipelineKey)

    /// Retrieves a pipeline by its type-safe key.
    ///
    /// - Parameter key: The type-safe key identifying the pipeline.
    /// - Returns: The registered pipeline, or `nil` if not found.
    public func pipeline<T: Command>(for key: PipelineKey<T>) -> (any Pipeline)? {
        entries[key.registryKey]?.pipeline
    }

    /// Retrieves the default pipeline for a command type.
    ///
    /// - Parameter commandType: The command type.
    /// - Returns: The default pipeline for this command type, or `nil` if not registered.
    public func pipeline<T: Command>(for commandType: T.Type) -> (any Pipeline)? {
        pipeline(for: PipelineKey<T>.default)
    }

    /// Retrieves a named pipeline for a command type.
    ///
    /// - Parameters:
    ///   - commandType: The command type.
    ///   - name: The pipeline name.
    /// - Returns: The named pipeline, or `nil` if not found.
    public func pipeline<T: Command>(for commandType: T.Type, named name: String) -> (any Pipeline)? {
        pipeline(for: PipelineKey<T>(name))
    }

    /// Retrieves all pipelines for a command type.
    ///
    /// - Parameter commandType: The command type.
    /// - Returns: Array of all pipelines registered for this command type.
    public func pipelines<T: Command>(for commandType: T.Type) -> [any Pipeline] {
        let typeID = ObjectIdentifier(T.self)
        guard let keys = byCommandType[typeID] else { return [] }
        return keys.compactMap { entries[$0]?.pipeline }
    }

    /// Retrieves all pipeline names for a command type.
    ///
    /// - Parameter commandType: The command type.
    /// - Returns: Array of pipeline names registered for this command type.
    public func pipelineNames<T: Command>(for commandType: T.Type) -> [String] {
        let typeID = ObjectIdentifier(T.self)
        guard let keys = byCommandType[typeID] else { return [] }
        return keys.compactMap { entries[$0]?.name }
    }

    // MARK: - Execution

    /// Executes a command using the default pipeline for its type.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: Optional context. If nil, a default context is created.
    /// - Returns: The command result.
    /// - Throws: `PipelineError.notFound` if no pipeline is registered, or any execution error.
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext? = nil
    ) async throws -> T.Result {
        guard let pipeline = pipeline(for: T.self) else {
            throw PipelineError.handlerNotFound(
                commandType: String(describing: T.self)
            )
        }
        let ctx = context ?? CommandContext()
        return try await pipeline.execute(command, context: ctx)
    }

    /// Executes a command using a specific named pipeline.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - name: The name of the pipeline to use.
    ///   - context: Optional context. If nil, a default context is created.
    /// - Returns: The command result.
    /// - Throws: `PipelineError.notFound` if no pipeline is registered, or any execution error.
    public func execute<T: Command>(
        _ command: T,
        using name: String,
        context: CommandContext? = nil
    ) async throws -> T.Result {
        guard let pipeline = pipeline(for: T.self, named: name) else {
            throw PipelineError.handlerNotFound(
                commandType: "\(T.self) (named: \(name))"
            )
        }
        let ctx = context ?? CommandContext()
        return try await pipeline.execute(command, context: ctx)
    }

    /// Executes a command using a type-safe pipeline key.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - key: The type-safe key identifying the pipeline.
    ///   - context: Optional context. If nil, a default context is created.
    /// - Returns: The command result.
    /// - Throws: `PipelineError.notFound` if no pipeline is registered, or any execution error.
    public func execute<T: Command>(
        _ command: T,
        using key: PipelineKey<T>,
        context: CommandContext? = nil
    ) async throws -> T.Result {
        guard let pipeline = pipeline(for: key) else {
            throw PipelineError.handlerNotFound(
                commandType: "\(T.self) (key: \(key.name))"
            )
        }
        let ctx = context ?? CommandContext()
        return try await pipeline.execute(command, context: ctx)
    }

    // MARK: - Removal

    /// Removes a pipeline by its type-safe key.
    ///
    /// - Parameter key: The key of the pipeline to remove.
    /// - Returns: The removed pipeline, or `nil` if not found.
    @discardableResult
    public func remove<T: Command>(for key: PipelineKey<T>) -> (any Pipeline)? {
        let registryKey = key.registryKey
        guard let entry = entries.removeValue(forKey: registryKey) else { return nil }

        byCommandType[entry.commandTypeID]?.remove(registryKey)
        if byCommandType[entry.commandTypeID]?.isEmpty == true {
            byCommandType.removeValue(forKey: entry.commandTypeID)
        }

        return entry.pipeline
    }

    /// Removes the default pipeline for a command type.
    ///
    /// - Parameter commandType: The command type.
    /// - Returns: The removed pipeline, or `nil` if not found.
    @discardableResult
    public func remove<T: Command>(for commandType: T.Type) -> (any Pipeline)? {
        remove(for: PipelineKey<T>.default)
    }

    /// Removes all pipelines for a command type.
    ///
    /// - Parameter commandType: The command type.
    /// - Returns: Array of removed pipelines.
    @discardableResult
    public func removeAll<T: Command>(for commandType: T.Type) -> [any Pipeline] {
        let typeID = ObjectIdentifier(T.self)
        guard let keys = byCommandType.removeValue(forKey: typeID) else { return [] }

        return keys.compactMap { key in
            entries.removeValue(forKey: key)?.pipeline
        }
    }

    /// Removes all registered pipelines.
    public func removeAll() {
        entries.removeAll()
        byCommandType.removeAll()
    }

    // MARK: - Introspection

    /// Checks if a pipeline is registered for a key.
    ///
    /// - Parameter key: The pipeline key to check.
    /// - Returns: `true` if a pipeline is registered.
    public func contains<T: Command>(_ key: PipelineKey<T>) -> Bool {
        entries[key.registryKey] != nil
    }

    /// Checks if any pipeline is registered for a command type.
    ///
    /// - Parameter commandType: The command type to check.
    /// - Returns: `true` if at least one pipeline is registered.
    public func contains<T: Command>(_ commandType: T.Type) -> Bool {
        let typeID = ObjectIdentifier(T.self)
        return byCommandType[typeID]?.isEmpty == false
    }

    /// Returns the total number of registered pipelines.
    public var count: Int {
        entries.count
    }

    /// Returns the number of unique command types with registered pipelines.
    public var commandTypeCount: Int {
        byCommandType.count
    }

    /// Returns whether the registry is empty.
    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Returns statistics about the registry.
    public func stats() -> RegistryStats {
        var pipelinesByType: [String: [String]] = [:]

        for (_, entry) in entries {
            pipelinesByType[entry.commandTypeName, default: []].append(entry.name)
        }

        return RegistryStats(
            pipelineCount: entries.count,
            commandTypeCount: byCommandType.count,
            pipelinesByType: pipelinesByType
        )
    }

    /// Returns all registered command type names.
    public var registeredCommandTypes: [String] {
        Array(Set(entries.values.map(\.commandTypeName)))
    }

    /// Returns all registered pipeline names.
    public var registeredPipelineNames: [String] {
        entries.values.map(\.name)
    }
}

// MARK: - Global Shared Instance

extension PipelineRegistry {
    /// A shared global pipeline registry.
    ///
    /// Use this for application-wide pipeline management when dependency injection
    /// is not practical.
    ///
    /// - Warning: For testability, prefer creating and injecting registry instances.
    public static let shared = PipelineRegistry()
}
