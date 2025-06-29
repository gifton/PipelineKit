import Foundation

/// A protocol that defines the core functionality for command execution pipelines.
public protocol Pipeline: Sendable {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result
}

public extension Pipeline {
    func execute<T: Command>(_ command: T) async throws -> T.Result {
        try await execute(command, metadata: DefaultCommandMetadata())
    }
}
