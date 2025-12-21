//
//  ExecutionRecorder.swift
//  PipelineKit
//
//  Records command execution history for debugging.
//

import Foundation
import PipelineKitCore

/// A record of a single command execution.
public struct ExecutionRecord: Sendable, Identifiable {
    /// Unique identifier for this record.
    public let id: UUID

    /// Type name of the executed command.
    public let commandType: String

    /// The command's ID from its metadata.
    public let commandID: UUID

    /// Correlation ID for distributed tracing.
    public let correlationID: String?

    /// When execution started.
    public let startTime: Date

    /// When execution completed.
    public let endTime: Date

    /// Total execution duration in seconds.
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Whether execution succeeded.
    public let succeeded: Bool

    /// Error message if execution failed.
    public let errorMessage: String?

    /// Error type if execution failed.
    public let errorType: String?

    /// Names of middleware that executed (in order).
    public let middlewareTrace: [String]

    /// Additional metadata captured during execution.
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        commandType: String,
        commandID: UUID,
        correlationID: String? = nil,
        startTime: Date,
        endTime: Date,
        succeeded: Bool,
        errorMessage: String? = nil,
        errorType: String? = nil,
        middlewareTrace: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.commandType = commandType
        self.commandID = commandID
        self.correlationID = correlationID
        self.startTime = startTime
        self.endTime = endTime
        self.succeeded = succeeded
        self.errorMessage = errorMessage
        self.errorType = errorType
        self.middlewareTrace = middlewareTrace
        self.metadata = metadata
    }
}

/// Actor that records command execution history.
///
/// `ExecutionRecorder` maintains a bounded history of command executions,
/// useful for debugging and monitoring.
///
/// ## Usage
///
/// ```swift
/// let recorder = ExecutionRecorder(maxRecords: 500)
///
/// // Use RecordingMiddleware to automatically capture executions
/// pipeline.use(RecordingMiddleware(recorder: recorder))
///
/// // Query execution history
/// let recent = await recorder.recent(limit: 10)
/// let failures = await recorder.failures(limit: 5)
/// let userCommands = await recorder.executions(
///     forCommandType: "CreateUserCommand",
///     limit: 20
/// )
/// ```
public actor ExecutionRecorder {

    // MARK: - Configuration

    /// Maximum number of records to retain.
    public var maxRecords: Int {
        didSet {
            trimIfNeeded()
        }
    }

    // MARK: - Storage

    /// Execution records in chronological order (oldest first).
    private var records: [ExecutionRecord] = []

    /// Index by command type for faster queries.
    private var byCommandType: [String: [UUID]] = [:]

    /// Set of failed execution IDs for fast failure queries.
    private var failedIDs: Set<UUID> = []

    // MARK: - Statistics

    /// Total executions recorded (including evicted).
    private var totalRecorded: Int = 0

    /// Total successful executions.
    private var totalSucceeded: Int = 0

    /// Total failed executions.
    private var totalFailed: Int = 0

    // MARK: - Initialization

    /// Creates a new execution recorder.
    ///
    /// - Parameter maxRecords: Maximum records to retain. Defaults to 1000.
    public init(maxRecords: Int = 1000) {
        self.maxRecords = maxRecords
    }

    // MARK: - Recording

    /// Records an execution.
    ///
    /// - Parameter record: The execution record to store.
    public func record(_ record: ExecutionRecord) {
        records.append(record)
        byCommandType[record.commandType, default: []].append(record.id)

        if !record.succeeded {
            failedIDs.insert(record.id)
        }

        totalRecorded += 1
        if record.succeeded {
            totalSucceeded += 1
        } else {
            totalFailed += 1
        }

        trimIfNeeded()
    }

    /// Records an execution from execution details.
    ///
    /// - Parameters:
    ///   - commandType: The command type name.
    ///   - commandID: The command's unique ID.
    ///   - correlationID: Optional correlation ID.
    ///   - startTime: When execution started.
    ///   - endTime: When execution completed.
    ///   - error: The error if execution failed.
    ///   - middlewareTrace: Names of executed middleware.
    ///   - metadata: Additional metadata.
    public func record(
        commandType: String,
        commandID: UUID,
        correlationID: String? = nil,
        startTime: Date,
        endTime: Date,
        error: (any Error)? = nil,
        middlewareTrace: [String] = [],
        metadata: [String: String] = [:]
    ) {
        let record = ExecutionRecord(
            commandType: commandType,
            commandID: commandID,
            correlationID: correlationID,
            startTime: startTime,
            endTime: endTime,
            succeeded: error == nil,
            errorMessage: error?.localizedDescription,
            errorType: error.map { String(describing: type(of: $0)) },
            middlewareTrace: middlewareTrace,
            metadata: metadata
        )
        self.record(record)
    }

    // MARK: - Queries

    /// Returns the most recent executions.
    ///
    /// - Parameter limit: Maximum number of records to return.
    /// - Returns: Array of recent records (newest first).
    public func recent(limit: Int = 10) -> [ExecutionRecord] {
        Array(records.suffix(limit).reversed())
    }

    /// Returns all stored executions.
    ///
    /// - Returns: Array of all records (oldest first).
    public func all() -> [ExecutionRecord] {
        records
    }

    /// Returns executions for a specific command type.
    ///
    /// - Parameters:
    ///   - commandType: The command type to filter by.
    ///   - limit: Maximum number of records to return.
    /// - Returns: Array of matching records (newest first).
    public func executions(forCommandType commandType: String, limit: Int = 10) -> [ExecutionRecord] {
        let ids = byCommandType[commandType] ?? []
        let matching = records.filter { ids.contains($0.id) }
        return Array(matching.suffix(limit).reversed())
    }

    /// Returns failed executions.
    ///
    /// - Parameter limit: Maximum number of records to return.
    /// - Returns: Array of failed records (newest first).
    public func failures(limit: Int = 10) -> [ExecutionRecord] {
        let failed = records.filter { failedIDs.contains($0.id) }
        return Array(failed.suffix(limit).reversed())
    }

    /// Returns successful executions.
    ///
    /// - Parameter limit: Maximum number of records to return.
    /// - Returns: Array of successful records (newest first).
    public func successes(limit: Int = 10) -> [ExecutionRecord] {
        let succeeded = records.filter { !failedIDs.contains($0.id) }
        return Array(succeeded.suffix(limit).reversed())
    }

    /// Returns executions within a time range.
    ///
    /// - Parameters:
    ///   - start: Start of the time range.
    ///   - end: End of the time range.
    /// - Returns: Array of matching records (oldest first).
    public func executions(from start: Date, to end: Date) -> [ExecutionRecord] {
        records.filter { $0.startTime >= start && $0.startTime <= end }
    }

    /// Returns executions with a specific correlation ID.
    ///
    /// - Parameter correlationID: The correlation ID to filter by.
    /// - Returns: Array of matching records (oldest first).
    public func executions(withCorrelationID correlationID: String) -> [ExecutionRecord] {
        records.filter { $0.correlationID == correlationID }
    }

    /// Finds a specific execution by ID.
    ///
    /// - Parameter id: The execution record ID.
    /// - Returns: The record if found.
    public func execution(withID id: UUID) -> ExecutionRecord? {
        records.first { $0.id == id }
    }

    // MARK: - Statistics

    /// Statistics about recorded executions.
    public struct Stats: Sendable {
        public let currentRecords: Int
        public let maxRecords: Int
        public let totalRecorded: Int
        public let totalSucceeded: Int
        public let totalFailed: Int
        public let successRate: Double
        public let commandTypes: Int
        public let averageDuration: TimeInterval?

        public var failureRate: Double { 1.0 - successRate }
    }

    /// Returns statistics about recorded executions.
    public func stats() -> Stats {
        let avgDuration: TimeInterval?
        if records.isEmpty {
            avgDuration = nil
        } else {
            avgDuration = records.map(\.duration).reduce(0, +) / Double(records.count)
        }

        let successRate: Double
        if totalRecorded == 0 {
            successRate = 1.0
        } else {
            successRate = Double(totalSucceeded) / Double(totalRecorded)
        }

        return Stats(
            currentRecords: records.count,
            maxRecords: maxRecords,
            totalRecorded: totalRecorded,
            totalSucceeded: totalSucceeded,
            totalFailed: totalFailed,
            successRate: successRate,
            commandTypes: byCommandType.count,
            averageDuration: avgDuration
        )
    }

    // MARK: - Management

    /// Clears all recorded executions.
    public func clear() {
        records.removeAll()
        byCommandType.removeAll()
        failedIDs.removeAll()
        // Note: lifetime statistics are preserved
    }

    /// Resets all statistics and records.
    public func reset() {
        clear()
        totalRecorded = 0
        totalSucceeded = 0
        totalFailed = 0
    }

    /// Returns the number of current records.
    public var count: Int {
        records.count
    }

    // MARK: - Private

    private func trimIfNeeded() {
        while records.count > maxRecords {
            let removed = records.removeFirst()

            // Update indexes
            byCommandType[removed.commandType]?.removeAll { $0 == removed.id }
            if byCommandType[removed.commandType]?.isEmpty == true {
                byCommandType.removeValue(forKey: removed.commandType)
            }
            failedIDs.remove(removed.id)
        }
    }
}

// MARK: - RecordingMiddleware

/// Middleware that automatically records executions to an ExecutionRecorder.
///
/// ## Usage
///
/// ```swift
/// let recorder = ExecutionRecorder()
/// let recording = RecordingMiddleware(recorder: recorder)
/// pipeline.use(recording)
/// ```
public struct RecordingMiddleware: Middleware, Sendable {
    public let priority: ExecutionPriority = .postProcessing
    private let recorder: ExecutionRecorder

    /// Creates a recording middleware.
    ///
    /// - Parameter recorder: The recorder to send executions to.
    public init(recorder: ExecutionRecorder) {
        self.recorder = recorder
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let startTime = Date()
        let commandType = String(describing: T.self)
        let commandID = context.commandMetadata.id

        do {
            let result = try await next(command, context)

            await recorder.record(
                commandType: commandType,
                commandID: commandID,
                correlationID: context.correlationID,
                startTime: startTime,
                endTime: Date(),
                error: nil,
                middlewareTrace: [],
                metadata: [:]
            )

            return result
        } catch {
            await recorder.record(
                commandType: commandType,
                commandID: commandID,
                correlationID: context.correlationID,
                startTime: startTime,
                endTime: Date(),
                error: error,
                middlewareTrace: [],
                metadata: [:]
            )

            throw error
        }
    }
}

// MARK: - ExecutionRecord Extensions

extension ExecutionRecord: CustomStringConvertible {
    public var description: String {
        let status = succeeded ? "OK" : "FAILED"
        let durationMs = String(format: "%.2fms", duration * 1000)
        return "[\(status)] \(commandType) (\(durationMs))"
    }
}

extension ExecutionRecord: CustomDebugStringConvertible {
    public var debugDescription: String {
        var lines = [
            "ExecutionRecord {",
            "  id: \(id)",
            "  commandType: \(commandType)",
            "  commandID: \(commandID)",
            "  correlationID: \(correlationID ?? "none")",
            "  startTime: \(startTime)",
            "  endTime: \(endTime)",
            "  duration: \(String(format: "%.4f", duration))s",
            "  succeeded: \(succeeded)"
        ]

        if let errorMessage = errorMessage {
            lines.append("  errorMessage: \(errorMessage)")
        }

        if let errorType = errorType {
            lines.append("  errorType: \(errorType)")
        }

        if !middlewareTrace.isEmpty {
            lines.append("  middlewareTrace: [\(middlewareTrace.joined(separator: ", "))]")
        }

        lines.append("}")

        return lines.joined(separator: "\n")
    }
}
