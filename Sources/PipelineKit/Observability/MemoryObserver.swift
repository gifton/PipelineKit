import Foundation

/// An observer that stores events in memory for later inspection
/// Useful for testing, debugging, and analyzing pipeline behavior
public actor MemoryObserver: PipelineObserver {
    
    /// Represents a recorded event with timestamp
    public struct RecordedEvent: Sendable {
        public let timestamp: Date
        public let event: Event
        
        public enum Event: Sendable {
            case pipelineStarted(command: String, pipeline: String, correlationId: String?)
            case pipelineCompleted(command: String, pipeline: String, duration: TimeInterval, correlationId: String?)
            case pipelineFailed(command: String, pipeline: String, error: String, duration: TimeInterval, correlationId: String?)
            case middlewareStarted(name: String, order: Int, correlationId: String)
            case middlewareCompleted(name: String, order: Int, duration: TimeInterval, correlationId: String)
            case middlewareFailed(name: String, order: Int, error: String, duration: TimeInterval, correlationId: String)
            case handlerStarted(command: String, handler: String, correlationId: String)
            case handlerCompleted(command: String, handler: String, duration: TimeInterval, correlationId: String)
            case handlerFailed(command: String, handler: String, error: String, duration: TimeInterval, correlationId: String)
            case custom(name: String, properties: [String: String], correlationId: String)
        }
    }
    
    /// Options for configuring the memory observer
    public struct Options: Sendable {
        /// Maximum number of events to store (oldest are removed when limit is reached)
        public let maxEvents: Int
        
        /// Whether to store middleware events
        public let captureMiddlewareEvents: Bool
        
        /// Whether to store handler events
        public let captureHandlerEvents: Bool
        
        /// Time interval for automatic cleanup (nil disables auto-cleanup)
        public let cleanupInterval: TimeInterval?
        
        public init(
            maxEvents: Int = 10000,
            captureMiddlewareEvents: Bool = true,
            captureHandlerEvents: Bool = true,
            cleanupInterval: TimeInterval? = nil
        ) {
            self.maxEvents = maxEvents
            self.captureMiddlewareEvents = captureMiddlewareEvents
            self.captureHandlerEvents = captureHandlerEvents
            self.cleanupInterval = cleanupInterval
        }
    }
    
    private var events: [RecordedEvent] = []
    private let options: Options
    private var cleanupTask: Task<Void, Never>?
    
    public init(options: Options = Options()) {
        self.options = options
        self.cleanupTask = nil
    }
    
    /// Start the cleanup task after initialization
    public func startCleanup() {
        guard let interval = options.cleanupInterval else { return }
        
        self.cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self.cleanup()
            }
        }
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    // MARK: - Event Recording
    
    private func record(_ event: RecordedEvent.Event) {
        autoreleasepool {
            let recordedEvent = RecordedEvent(timestamp: Date(), event: event)
            events.append(recordedEvent)
            
            // Trim if we exceed max events
            if events.count > options.maxEvents {
                events.removeFirst(events.count - options.maxEvents)
            }
        }
    }
    
    // MARK: - PipelineObserver Implementation
    
    public func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
        record(.pipelineStarted(
            command: String(describing: type(of: command)),
            pipeline: pipelineType,
            correlationId: metadata.correlationId
        ))
    }
    
    public func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        record(.pipelineCompleted(
            command: String(describing: type(of: command)),
            pipeline: pipelineType,
            duration: duration,
            correlationId: metadata.correlationId
        ))
    }
    
    public func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        record(.pipelineFailed(
            command: String(describing: type(of: command)),
            pipeline: pipelineType,
            error: error.localizedDescription,
            duration: duration,
            correlationId: metadata.correlationId
        ))
    }
    
    public func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
        guard options.captureMiddlewareEvents else { return }
        record(.middlewareStarted(name: middlewareName, order: order, correlationId: correlationId))
    }
    
    public func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
        guard options.captureMiddlewareEvents else { return }
        record(.middlewareCompleted(name: middlewareName, order: order, duration: duration, correlationId: correlationId))
    }
    
    public func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
        guard options.captureMiddlewareEvents else { return }
        record(.middlewareFailed(
            name: middlewareName,
            order: order,
            error: error.localizedDescription,
            duration: duration,
            correlationId: correlationId
        ))
    }
    
    public func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
        guard options.captureHandlerEvents else { return }
        record(.handlerStarted(
            command: String(describing: type(of: command)),
            handler: handlerType,
            correlationId: correlationId
        ))
    }
    
    public func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
        guard options.captureHandlerEvents else { return }
        record(.handlerCompleted(
            command: String(describing: type(of: command)),
            handler: handlerType,
            duration: duration,
            correlationId: correlationId
        ))
    }
    
    public func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
        guard options.captureHandlerEvents else { return }
        record(.handlerFailed(
            command: String(describing: type(of: command)),
            handler: handlerType,
            error: error.localizedDescription,
            duration: duration,
            correlationId: correlationId
        ))
    }
    
    public func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
        // Convert properties to string representation
        let stringProperties = properties.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
        record(.custom(name: eventName, properties: stringProperties, correlationId: correlationId))
    }
    
    // MARK: - Query Methods
    
    /// Get all recorded events
    public func allEvents() -> [RecordedEvent] {
        return events
    }
    
    /// Get events for a specific correlation ID
    public func events(for correlationId: String) -> [RecordedEvent] {
        return events.filter { event in
            switch event.event {
            case .pipelineStarted(_, _, let id),
                 .pipelineCompleted(_, _, _, let id),
                 .pipelineFailed(_, _, _, _, let id):
                return id == correlationId
            case .middlewareStarted(_, _, let id),
                 .middlewareCompleted(_, _, _, let id),
                 .middlewareFailed(_, _, _, _, let id),
                 .handlerStarted(_, _, let id),
                 .handlerCompleted(_, _, _, let id),
                 .handlerFailed(_, _, _, _, let id),
                 .custom(_, _, let id):
                return id == correlationId
            }
        }
    }
    
    /// Get pipeline events only
    public func pipelineEvents() -> [RecordedEvent] {
        return events.filter { event in
            switch event.event {
            case .pipelineStarted, .pipelineCompleted, .pipelineFailed:
                return true
            default:
                return false
            }
        }
    }
    
    /// Get error events only
    public func errorEvents() -> [RecordedEvent] {
        return events.filter { event in
            switch event.event {
            case .pipelineFailed, .middlewareFailed, .handlerFailed:
                return true
            default:
                return false
            }
        }
    }
    
    /// Clear all recorded events
    public func clear() {
        events.removeAll()
    }
    
    /// Remove events older than the specified date
    public func removeEvents(before date: Date) {
        events.removeAll { $0.timestamp < date }
    }
    
    /// Cleanup old events based on cleanup interval
    private func cleanup() {
        guard let interval = options.cleanupInterval else { return }
        let cutoffDate = Date().addingTimeInterval(-interval)
        removeEvents(before: cutoffDate)
    }
    
    // MARK: - Statistics
    
    /// Get basic statistics about recorded events
    public func statistics() -> Statistics {
        var pipelineCount = 0
        var successCount = 0
        var failureCount = 0
        var totalDuration: TimeInterval = 0
        var commandCounts: [String: Int] = [:]
        
        autoreleasepool {
            for event in events {
                switch event.event {
                case .pipelineStarted(let command, _, _):
                    pipelineCount += 1
                    commandCounts[command, default: 0] += 1
                case .pipelineCompleted(_, _, let duration, _):
                    successCount += 1
                    totalDuration += duration
                case .pipelineFailed(_, _, _, let duration, _):
                    failureCount += 1
                    totalDuration += duration
                default:
                    break
                }
            }
        }
        
        return Statistics(
            totalEvents: events.count,
            pipelineExecutions: pipelineCount,
            successfulExecutions: successCount,
            failedExecutions: failureCount,
            averageDuration: pipelineCount > 0 ? totalDuration / Double(pipelineCount) : 0,
            commandCounts: commandCounts
        )
    }
    
    public struct Statistics: Sendable {
        public let totalEvents: Int
        public let pipelineExecutions: Int
        public let successfulExecutions: Int
        public let failedExecutions: Int
        public let averageDuration: TimeInterval
        public let commandCounts: [String: Int]
    }
}

// MARK: - Convenience Extensions

public extension MemoryObserver {
    /// Wait for a specific number of pipeline completions
    func waitForPipelineCompletions(_ count: Int, timeout: TimeInterval = 5.0) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            let completions = pipelineEvents().filter { event in
                switch event.event {
                case .pipelineCompleted, .pipelineFailed:
                    return true
                default:
                    return false
                }
            }.count
            
            if completions >= count {
                return true
            }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        return false
    }
}