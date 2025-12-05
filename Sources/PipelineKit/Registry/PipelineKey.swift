//
//  PipelineKey.swift
//  PipelineKit
//
//  Type-safe keys for pipeline registration and retrieval.
//

import Foundation
import PipelineKitCore

/// A type-safe key for registering and retrieving pipelines.
///
/// `PipelineKey` provides compile-time type safety for pipeline registry operations.
/// The generic parameter `T` specifies the command type that the pipeline handles.
///
/// ## Usage
///
/// ```swift
/// // Define keys for your pipelines
/// extension PipelineKey where T == CreateUserCommand {
///     static let createUser = PipelineKey("createUser")
///     static let adminCreateUser = PipelineKey("adminCreateUser")
/// }
///
/// // Register pipelines
/// await registry.register(userPipeline, for: .createUser)
/// await registry.register(adminPipeline, for: .adminCreateUser)
///
/// // Retrieve pipelines
/// let pipeline = await registry.pipeline(for: PipelineKey<CreateUserCommand>.createUser)
/// ```
///
/// ## Named Pipelines
///
/// Multiple pipelines can handle the same command type with different configurations.
/// Use meaningful names to distinguish them:
///
/// ```swift
/// extension PipelineKey where T == ProcessOrderCommand {
///     static let standard = PipelineKey("standard")
///     static let priority = PipelineKey("priority")
///     static let bulk = PipelineKey("bulk")
/// }
/// ```
@frozen
public struct PipelineKey<T: Command>: Hashable, Sendable {
    /// The unique name for this pipeline key.
    public let name: String

    /// The command type this key is associated with.
    public var commandType: T.Type { T.self }

    /// Creates a new pipeline key with the specified name.
    ///
    /// - Parameter name: A unique identifier for the pipeline. Defaults to "default".
    public init(_ name: String = "default") {
        self.name = name
    }

    /// The default pipeline key for a command type.
    public static var `default`: PipelineKey<T> {
        PipelineKey("default")
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(ObjectIdentifier(T.self))
    }

    public static func == (lhs: PipelineKey<T>, rhs: PipelineKey<T>) -> Bool {
        lhs.name == rhs.name
    }
}

// MARK: - Internal Helpers

extension PipelineKey {
    /// Internal composite key for registry storage.
    var registryKey: String {
        "\(ObjectIdentifier(T.self)):\(name)"
    }
}

// MARK: - CustomStringConvertible

extension PipelineKey: CustomStringConvertible {
    public var description: String {
        "PipelineKey<\(T.self)>(\(name))"
    }
}

// MARK: - CustomDebugStringConvertible

extension PipelineKey: CustomDebugStringConvertible {
    public var debugDescription: String {
        "PipelineKey(command: \(T.self), name: \"\(name)\")"
    }
}
