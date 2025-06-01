import Foundation

/// Journal entry for command persistence
public struct JournalEntry: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let commandType: String
    public let commandData: Data
    public let metadata: Data
    public let status: JournalEntryStatus
    
    public enum JournalEntryStatus: String, Codable, Sendable {
        case pending
        case executing
        case completed
        case failed
        case compensated
    }
}

/// Protocol for commands that can be persisted
public protocol PersistableCommand: Command, Codable {
    static var commandType: String { get }
}

/// Command journal for write-ahead logging
public actor CommandJournal {
    private let storage: JournalStorage
    private let serializer: CommandSerializer
    private var activeEntries: [UUID: JournalEntry] = [:]
    
    public init(storage: JournalStorage, serializer: CommandSerializer) {
        self.storage = storage
        self.serializer = serializer
    }
    
    /// Append a command to the journal
    public func append<T: PersistableCommand>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> UUID {
        let entryId = UUID()
        
        let commandData = try serializer.serialize(command)
        // Serialize metadata properties we can access
        let metadataDict: [String: String] = [
            "correlationId": metadata.correlationId ?? UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: metadata.timestamp)
        ]
        let metadataData = try serializer.serialize(metadataDict)
        
        let entry = JournalEntry(
            id: entryId,
            timestamp: Date(),
            commandType: T.commandType,
            commandData: commandData,
            metadata: metadataData,
            status: .pending
        )
        
        try await storage.write(entry)
        activeEntries[entryId] = entry
        
        return entryId
    }
    
    /// Update entry status
    public func updateStatus(_ entryId: UUID, status: JournalEntry.JournalEntryStatus) async throws {
        guard let entry = activeEntries[entryId] else {
            throw JournalError.entryNotFound(entryId)
        }
        
        let updatedEntry = JournalEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            commandType: entry.commandType,
            commandData: entry.commandData,
            metadata: entry.metadata,
            status: status
        )
        
        try await storage.update(updatedEntry)
        activeEntries[entryId] = updatedEntry
        
        // Remove completed entries from memory
        if status == .completed || status == .compensated {
            activeEntries.removeValue(forKey: entryId)
        }
    }
    
    /// Mark entry as complete
    public func complete(_ entryId: UUID) async throws {
        try await updateStatus(entryId, status: .completed)
    }
    
    /// Mark entry as failed
    public func fail(_ entryId: UUID, error: Error) async throws {
        try await updateStatus(entryId, status: .failed)
        // Could also store error details
    }
    
    /// Recover incomplete entries after restart
    public func recoverIncompleteEntries() async throws -> [RecoverableEntry] {
        let entries = try await storage.readIncomplete()
        
        var recoverableEntries: [RecoverableEntry] = []
        for entry in entries {
            if let recoverable = try await createRecoverableEntry(from: entry) {
                recoverableEntries.append(recoverable)
                activeEntries[entry.id] = entry
            }
        }
        
        return recoverableEntries
    }
    
    private func createRecoverableEntry(from entry: JournalEntry) async throws -> RecoverableEntry? {
        // Skip if too old (e.g., > 24 hours)
        let age = Date().timeIntervalSince(entry.timestamp)
        guard age < 86400 else { // 24 hours
            try await updateStatus(entry.id, status: .failed)
            return nil
        }
        
        return RecoverableEntry(
            id: entry.id,
            commandType: entry.commandType,
            commandData: entry.commandData,
            metadata: entry.metadata,
            originalTimestamp: entry.timestamp
        )
    }
    
    /// Clean up old entries
    public func cleanup(olderThan date: Date) async throws {
        try await storage.deleteCompleted(before: date)
    }
}

/// Recoverable entry that can be replayed
public struct RecoverableEntry: Sendable {
    public let id: UUID
    public let commandType: String
    public let commandData: Data
    public let metadata: Data
    public let originalTimestamp: Date
}

/// Storage protocol for journal entries
public protocol JournalStorage: Sendable {
    func write(_ entry: JournalEntry) async throws
    func update(_ entry: JournalEntry) async throws
    func readIncomplete() async throws -> [JournalEntry]
    func deleteCompleted(before date: Date) async throws
}

/// File-based journal storage
public actor FileJournalStorage: JournalStorage {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init(directory: URL) async throws {
        self.directory = directory
        
        // Create directory if needed
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
    
    public func write(_ entry: JournalEntry) async throws {
        let data = try encoder.encode(entry)
        let fileURL = directory.appendingPathComponent("\(entry.id.uuidString).journal")
        try data.write(to: fileURL, options: .atomic)
    }
    
    public func update(_ entry: JournalEntry) async throws {
        try await write(entry) // Overwrite
    }
    
    public func readIncomplete() async throws -> [JournalEntry] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "journal" }
        
        var entries: [JournalEntry] = []
        
        for fileURL in fileURLs {
            do {
                let data = try Data(contentsOf: fileURL)
                let entry = try decoder.decode(JournalEntry.self, from: data)
                
                if entry.status == .pending || entry.status == .executing {
                    entries.append(entry)
                }
            } catch {
                // Log error but continue with other files
                print("Failed to read journal entry at \(fileURL): \(error)")
            }
        }
        
        return entries.sorted { $0.timestamp < $1.timestamp }
    }
    
    public func deleteCompleted(before date: Date) async throws {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "journal" }
        
        for fileURL in fileURLs {
            do {
                let data = try Data(contentsOf: fileURL)
                let entry = try decoder.decode(JournalEntry.self, from: data)
                
                if (entry.status == .completed || entry.status == .failed) && 
                   entry.timestamp < date {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                // Log error but continue
                print("Failed to process journal entry at \(fileURL): \(error)")
            }
        }
    }
}

/// Command serializer for encoding/decoding commands
public protocol CommandSerializer: Sendable {
    func serialize<T: Encodable>(_ value: T) throws -> Data
    func deserialize<T: Decodable>(_ data: Data, as type: T.Type) throws -> T
}

/// JSON-based command serializer
public struct JSONCommandSerializer: CommandSerializer {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    public func serialize<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
    
    public func deserialize<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        try decoder.decode(type, from: data)
    }
}

/// Journal errors
public enum JournalError: LocalizedError {
    case entryNotFound(UUID)
    case serializationFailed(Error)
    case storageFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .entryNotFound(let id):
            return "Journal entry not found: \(id)"
        case .serializationFailed(let error):
            return "Failed to serialize: \(error.localizedDescription)"
        case .storageFailed(let error):
            return "Storage operation failed: \(error.localizedDescription)"
        }
    }
}