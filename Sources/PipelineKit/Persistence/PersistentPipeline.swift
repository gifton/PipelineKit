import Foundation

/// Pipeline with persistence and recovery capabilities
public actor PersistentPipeline<T: PersistableCommand, H: CommandHandler>: Pipeline where H.CommandType == T {
    private let basePipeline: any Pipeline
    private let journal: CommandJournal
    private let recoveryHandler: RecoveryHandler?
    
    /// Recovery handler for custom recovery logic
    public typealias RecoveryHandler = @Sendable (RecoverableEntry) async throws -> Bool
    
    public init(
        pipeline: any Pipeline,
        journal: CommandJournal,
        recoveryHandler: RecoveryHandler? = nil
    ) {
        self.basePipeline = pipeline
        self.journal = journal
        self.recoveryHandler = recoveryHandler
    }
    
    /// Convenience initializer with file-based storage
    public init(
        pipeline: any Pipeline,
        persistenceDirectory: URL,
        recoveryHandler: RecoveryHandler? = nil
    ) async throws {
        self.basePipeline = pipeline
        self.recoveryHandler = recoveryHandler
        
        let storage = try await FileJournalStorage(directory: persistenceDirectory)
        self.journal = CommandJournal(
            storage: storage,
            serializer: JSONCommandSerializer()
        )
    }
    
    public func execute<C: Command>(_ command: C, metadata: CommandMetadata) async throws -> C.Result {
        guard let persistableCommand = command as? T else {
            // If not persistable, execute directly
            return try await basePipeline.execute(command, metadata: metadata)
        }
        
        // Journal the command
        let entryId = try await journal.append(persistableCommand, metadata: metadata)
        
        do {
            // Update status to executing
            try await journal.updateStatus(entryId, status: .executing)
            
            // Execute through base pipeline
            let result = try await basePipeline.execute(command, metadata: metadata)
            
            // Mark as complete
            try await journal.complete(entryId)
            
            return result
        } catch {
            // Mark as failed
            try await journal.fail(entryId, error: error)
            throw error
        }
    }
    
    /// Recover and replay incomplete commands after restart
    public func recoverIncompleteCommands() async throws -> RecoveryReport {
        let recoverableEntries = try await journal.recoverIncompleteEntries()
        
        var recovered = 0
        var failed = 0
        var skipped = 0
        
        for entry in recoverableEntries {
            do {
                // Check if custom recovery handler wants to skip
                if let handler = recoveryHandler {
                    let shouldRecover = try await handler(entry)
                    if !shouldRecover {
                        skipped += 1
                        try await journal.updateStatus(entry.id, status: .compensated)
                        continue
                    }
                }
                
                // Attempt recovery
                try await recoverEntry(entry)
                recovered += 1
            } catch {
                failed += 1
                try await journal.fail(entry.id, error: error)
            }
        }
        
        return RecoveryReport(
            totalEntries: recoverableEntries.count,
            recovered: recovered,
            failed: failed,
            skipped: skipped
        )
    }
    
    private func recoverEntry(_ entry: RecoverableEntry) async throws {
        // This is a simplified recovery - in practice, you'd need command type registry
        // For now, we'll mark it as requiring manual intervention
        throw RecoveryError.manualInterventionRequired(entry.id)
    }
    
    /// Clean up old journal entries
    public func cleanupJournal(olderThan days: Int = 7) async throws {
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -days,
            to: Date()
        )!
        
        try await journal.cleanup(olderThan: cutoffDate)
    }
}

/// Recovery report
public struct RecoveryReport: Sendable {
    public let totalEntries: Int
    public let recovered: Int
    public let failed: Int
    public let skipped: Int
    
    public var successRate: Double {
        guard totalEntries > 0 else { return 1.0 }
        return Double(recovered) / Double(totalEntries)
    }
}

/// Recovery errors
public enum RecoveryError: LocalizedError {
    case manualInterventionRequired(UUID)
    case commandTypeNotFound(String)
    case deserializationFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .manualInterventionRequired(let id):
            return "Manual intervention required for entry: \(id)"
        case .commandTypeNotFound(let type):
            return "Command type not found in registry: \(type)"
        case .deserializationFailed(let error):
            return "Failed to deserialize command: \(error.localizedDescription)"
        }
    }
}

/// Checkpoint system for long-running operations
public actor CheckpointManager {
    private let storage: CheckpointStorage
    private var activeCheckpoints: [UUID: Checkpoint] = [:]
    
    public init(storage: CheckpointStorage) {
        self.storage = storage
    }
    
    /// Create a checkpoint
    public func checkpoint<T: Codable>(
        id: UUID,
        state: T,
        metadata: [String: String] = [:]
    ) async throws {
        let checkpoint = Checkpoint(
            id: id,
            timestamp: Date(),
            stateData: try JSONEncoder().encode(state),
            metadata: metadata
        )
        
        try await storage.save(checkpoint)
        activeCheckpoints[id] = checkpoint
    }
    
    /// Restore from checkpoint
    public func restore<T: Codable>(
        id: UUID,
        as type: T.Type
    ) async throws -> T? {
        if let checkpoint = activeCheckpoints[id] {
            return try JSONDecoder().decode(type, from: checkpoint.stateData)
        }
        
        if let checkpoint = try await storage.load(id: id) {
            activeCheckpoints[id] = checkpoint
            return try JSONDecoder().decode(type, from: checkpoint.stateData)
        }
        
        return nil
    }
    
    /// Remove checkpoint
    public func remove(id: UUID) async throws {
        activeCheckpoints.removeValue(forKey: id)
        try await storage.delete(id: id)
    }
}

/// Checkpoint data
public struct Checkpoint: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let stateData: Data
    public let metadata: [String: String]
}

/// Checkpoint storage protocol
public protocol CheckpointStorage: Sendable {
    func save(_ checkpoint: Checkpoint) async throws
    func load(id: UUID) async throws -> Checkpoint?
    func delete(id: UUID) async throws
    func listAll() async throws -> [Checkpoint]
}

/// Memory-based checkpoint storage for testing
public actor InMemoryCheckpointStorage: CheckpointStorage {
    private var checkpoints: [UUID: Checkpoint] = [:]
    
    public init() {}
    
    public func save(_ checkpoint: Checkpoint) async throws {
        checkpoints[checkpoint.id] = checkpoint
    }
    
    public func load(id: UUID) async throws -> Checkpoint? {
        checkpoints[id]
    }
    
    public func delete(id: UUID) async throws {
        checkpoints.removeValue(forKey: id)
    }
    
    public func listAll() async throws -> [Checkpoint] {
        Array(checkpoints.values)
    }
}

/// Pipeline with checkpointing support
public final class CheckpointingMiddleware: Middleware {
    private let checkpointManager: CheckpointManager
    private let shouldCheckpoint: @Sendable (Any) -> Bool
    
    public init(
        checkpointManager: CheckpointManager,
        shouldCheckpoint: @escaping @Sendable (Any) -> Bool = { _ in true }
    ) {
        self.checkpointManager = checkpointManager
        self.shouldCheckpoint = shouldCheckpoint
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        guard shouldCheckpoint(command) else {
            return try await next(command, metadata)
        }
        
        let checkpointId = UUID()
        
        // Create initial checkpoint if command is Codable
        if let codableCommand = command as? (any Codable) {
            try await checkpointManager.checkpoint(
                id: checkpointId,
                state: codableCommand,
                metadata: ["stage": "pre-execution"]
            )
        }
        
        do {
            let result = try await next(command, metadata)
            
            // Clean up checkpoint on success
            try await checkpointManager.remove(id: checkpointId)
            
            return result
        } catch {
            // Checkpoint remains for potential recovery
            throw error
        }
    }
}