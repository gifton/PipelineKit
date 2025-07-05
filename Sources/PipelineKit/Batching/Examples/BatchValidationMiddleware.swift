import Foundation

/// Example of batch-optimized validation middleware
public struct BatchValidationMiddleware: BatchAwareMiddleware {
    public var priority: ExecutionPriority { .validation }
    
    public init() {}
    
    public func executeBatch<T: Command>(
        _ commands: [(command: T, context: CommandContext)],
        batchContext: BatchContext,
        next: @Sendable ([(T, CommandContext)]) async throws -> [T.Result]
    ) async throws -> [T.Result] {
        // Batch validation can be more efficient than individual validation
        print("Validating batch of \(commands.count) commands (batch ID: \(batchContext.batchId))")
        
        // Example: Check for duplicate IDs in batch
        if T.self == CreateUserCommand.self {
            let userCommands = commands.compactMap { $0.command as? CreateUserCommand }
            let emails = userCommands.map { $0.email }
            let uniqueEmails = Set(emails)
            
            if emails.count != uniqueEmails.count {
                throw BatchValidationError.duplicatesInBatch
            }
        }
        
        // Example: Validate all commands in parallel
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (command, _) in commands {
                group.addTask {
                    if let validatable = command as? any ValidatableCommand {
                        try await validatable.validate()
                    }
                }
            }
            
            // Wait for all validations to complete
            try await group.waitForAll()
        }
        
        // All valid, proceed to next
        return try await next(commands)
    }
}

/// Example of batch-optimized database middleware
public struct BatchDatabaseMiddleware: BatchAwareMiddleware {
    public var priority: ExecutionPriority { .custom }
    
    private let connectionPool: DatabaseConnectionPool
    
    public init(connectionPool: DatabaseConnectionPool) {
        self.connectionPool = connectionPool
    }
    
    public func executeBatch<T: Command>(
        _ commands: [(command: T, context: CommandContext)],
        batchContext: BatchContext,
        next: @Sendable ([(T, CommandContext)]) async throws -> [T.Result]
    ) async throws -> [T.Result] {
        // Acquire single connection for entire batch
        let connection = try await connectionPool.acquire()
        defer {
            Task {
                await connectionPool.release(connection)
            }
        }
        
        // Start transaction for batch
        try await connection.beginTransaction()
        
        do {
            // Store connection in context for handlers to use
            for (_, context) in commands {
                await context.set(connection, for: DatabaseConnectionKey.self)
            }
            
            // Execute all commands
            let results = try await next(commands)
            
            // Commit transaction
            try await connection.commit()
            
            return results
        } catch {
            // Rollback on any error
            try await connection.rollback()
            throw error
        }
    }
}

/// Example of batch-optimized caching middleware
public struct BatchCacheMiddleware: BatchAwareMiddleware {
    public var priority: ExecutionPriority { .cache }
    
    private let cache: DistributedCache
    
    public init(cache: DistributedCache) {
        self.cache = cache
    }
    
    public func executeBatch<T: Command>(
        _ commands: [(command: T, context: CommandContext)],
        batchContext: BatchContext,
        next: @Sendable ([(T, CommandContext)]) async throws -> [T.Result]
    ) async throws -> [T.Result] {
        // Check cache for all commands at once
        let cacheKeys = commands.map { CacheKey(command: $0.command) }
        let cachedResults = try await cache.multiGet(keys: cacheKeys)
        
        var results: [T.Result?] = Array(repeating: nil, count: commands.count)
        var uncachedIndices: [Int] = []
        var uncachedCommands: [(T, CommandContext)] = []
        
        // Separate cached vs uncached
        for (index, cached) in cachedResults.enumerated() {
            if let result = cached as? T.Result {
                results[index] = result
            } else {
                uncachedIndices.append(index)
                uncachedCommands.append(commands[index])
            }
        }
        
        // Process uncached commands
        if !uncachedCommands.isEmpty {
            let newResults = try await next(uncachedCommands)
            
            // Store in cache and results array
            var cacheUpdates: [(CacheKey, T.Result)] = []
            for (i, result) in newResults.enumerated() {
                let originalIndex = uncachedIndices[i]
                results[originalIndex] = result
                cacheUpdates.append((cacheKeys[originalIndex], result))
            }
            
            // Batch cache update
            try await cache.multiSet(cacheUpdates, ttl: 3600)
        }
        
        return results.compactMap { $0 }
    }
}

// MARK: - Supporting Types

enum BatchValidationError: LocalizedError {
    case duplicatesInBatch
    case batchSizeExceeded
    case invalidBatchConfiguration
    
    var errorDescription: String? {
        switch self {
        case .duplicatesInBatch:
            return "Duplicate entries found in batch"
        case .batchSizeExceeded:
            return "Batch size exceeds maximum allowed"
        case .invalidBatchConfiguration:
            return "Invalid batch configuration"
        }
    }
}

// Mock types for examples
public protocol DatabaseConnectionPool: Sendable {
    func acquire() async throws -> DatabaseConnection
    func release(_ connection: DatabaseConnection) async
}

public protocol DatabaseConnection: Sendable {
    func beginTransaction() async throws
    func commit() async throws
    func rollback() async throws
}

public protocol DistributedCache: Sendable {
    func multiGet<T>(keys: [CacheKey]) async throws -> [T?]
    func multiSet<T>(_ items: [(CacheKey, T)], ttl: TimeInterval) async throws
}

public struct CacheKey: Hashable, Sendable {
    let value: String
    
    init<T: Command>(command: T) {
        self.value = String(describing: command)
    }
}

struct DatabaseConnectionKey: ContextKey {
    typealias Value = DatabaseConnection
}

struct CreateUserCommand: Command, ValidatableCommand {
    typealias Result = User
    let email: String
    let name: String
    
    func validate() async throws {
        guard email.contains("@") else {
            throw ValidationError.invalidEmail
        }
    }
}

struct User: Sendable {
    let id: String
    let email: String
    let name: String
}

enum ValidationError: Error {
    case invalidEmail
}

extension ExecutionPriority {
    static let cache = ExecutionPriority(rawValue: 50)