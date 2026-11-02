import Foundation

/// UDP transport for sending metrics over the network.
public actor UDPTransport: MetricsTransport {
    public struct Configuration: Sendable {
        public let host: String
        public let port: Int
        public let timeout: TimeInterval
        public let connectionTimeout: TimeInterval
        public let maxRetries: Int

        public init(
            host: String = "localhost",
            port: Int = 8125,
            timeout: TimeInterval = 1.0,
            connectionTimeout: TimeInterval = 5.0,
            maxRetries: Int = 3
        ) {
            self.host = host
            self.port = port
            self.timeout = timeout
            self.connectionTimeout = connectionTimeout
            self.maxRetries = maxRetries
        }
    }

    private enum OperationKind {
        case setup, send, backoff
    }

    private struct PendingOperation {
        let kind: OperationKind
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }

    private enum Event: Sendable {
        case state(UDPConnectionState)
        case sent(UUID, Result<Void, TransportError>)
    }

    private let configuration: Configuration
    private let driver: any UDPConnectionDriver
    private let sleep: @Sendable (Duration) async throws -> Void
    private let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var eventTask: Task<Void, Never>?
    private var pending: [UUID: PendingOperation] = [:]
    private var setupID: UUID?
    private var started = false
    private var ready = false
    private var terminalError: (any Error)?

    // An internal ownership snapshot accompanies the injected driver/clock seam.
    var pendingOperationCount: Int { pending.count }

    public init(configuration: Configuration) async throws {
        try Self.validate(configuration)
        #if canImport(Network)
        try self.init(configuration: configuration, driver: NetworkUDPConnectionDriver(configuration: configuration))
        try await startConnection()
        #else
        throw TransportError.connectionFailed("Network framework not available")
        #endif
    }

    internal init(
        configuration: Configuration,
        driver: any UDPConnectionDriver,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        self.driver = driver
        self.sleep = sleep
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    deinit {
        eventContinuation.finish()
        eventTask?.cancel()
        driver.cancel()
    }

    internal func startConnection() async throws {
        guard !started else { throw TransportError.connectionFailed("Connection already started") }
        started = true
        let events = events
        eventTask = Task { [weak self] in
            // A single stream consumer preserves the driver's callback order;
            // separate Tasks for each state could reorder ready and cancelled.
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        try await perform(.setup, duration: Self.duration(configuration.connectionTimeout)) { id in
            self.setupID = id
            let continuation = self.eventContinuation
            self.driver.start { continuation.yield(.state($0)) }
        }
    }

    /// A timeout or caller cancellation invalidates this transport, including sibling sends.
    /// Create a new transport after failure. UDP completion does not acknowledge delivery.
    /// Lifecycle coverage: `UDPTransportLifecycleTests.testMissingSendCallbackSettlesOnTimeoutOrClose`.
    public func send(_ data: Data) async throws {
        for attempt in 0..<configuration.maxRetries {
            do {
                try await perform(.send, duration: Self.duration(configuration.timeout)) { id in
                    let continuation = self.eventContinuation
                    self.driver.send(data) { continuation.yield(.sent(id, $0)) }
                }
                return
            } catch let error as TransportError {
                guard case .sendFailed = error, attempt < configuration.maxRetries - 1 else { throw error }
                // Backoff is registered too: close/cancellation must settle it without
                // waiting for the delay (testRetryBackoffIsOwnedByCancellationAndClose).
                try await perform(.backoff, duration: .seconds(Double(attempt + 1) * 0.1)) { _ in }
            }
        }
    }

    public func sendBatch(_ batch: [Data]) async throws {
        if let terminalError { throw terminalError }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for data in batch {
                group.addTask { try await self.send(data) }
            }
            do {
                for try await _ in group {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    public func close() async {
        invalidate(TransportError.transportClosed)
        // Explicit close has a stable public error even after an earlier failure.
        terminalError = TransportError.transportClosed
        await eventTask?.value
    }

    private func perform(
        _ kind: OperationKind,
        duration: Duration,
        begin: (UUID) -> Void
    ) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    invalidate(CancellationError())
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let terminalError {
                    continuation.resume(throwing: terminalError)
                    return
                }
                guard kind == .setup || ready else {
                    continuation.resume(throwing: TransportError.connectionFailed("Connection not ready"))
                    return
                }
                let sleep = self.sleep
                let timer = Task { [weak self] in
                    do {
                        try Task.checkCancellation()
                        try await sleep(duration)
                        try Task.checkCancellation()
                        await self?.deadlineReached(id)
                    } catch {
                        // Settlement cancels this timer after removing its operation.
                    }
                }
                pending[id] = PendingOperation(kind: kind, continuation: continuation, timer: timer)
                begin(id)
            }
        } onCancel: {
            Task { await self.cancelOperation(id) }
        }
    }

    private func handle(_ event: Event) {
        guard terminalError == nil else { return }
        switch event {
        case .state(.ready):
            guard let setupID, pending[setupID] != nil else { return }
            ready = true
            settle(setupID, with: .success(()))
        case .state(.failed(let error)):
            invalidate(error)
        case .state(.cancelled):
            invalidate(TransportError.transportClosed)
        case .sent(let id, let result):
            guard pending[id]?.kind == .send else { return }
            switch result {
            case .success:
                settle(id, with: .success(()))
            case .failure(.sendFailed(let message)):
                settle(id, with: .failure(TransportError.sendFailed(message)))
            case .failure(let error):
                invalidate(error)
            }
        }
    }

    private func deadlineReached(_ id: UUID) {
        guard let operation = pending[id] else { return }
        if operation.kind == .backoff {
            settle(id, with: .success(()))
        } else {
            invalidate(TransportError.timeout)
        }
    }

    private func cancelOperation(_ id: UUID) {
        // A cancellation delivered after completion does not cancel another operation.
        guard pending[id] != nil else { return }
        invalidate(CancellationError())
    }

    private func invalidate(_ error: any Error) {
        guard terminalError == nil else { return }
        terminalError = error
        ready = false
        eventContinuation.finish()
        eventTask?.cancel()
        driver.cancel()
        for id in Array(pending.keys) { settle(id, with: .failure(error)) }
    }

    private func settle(_ id: UUID, with result: Result<Void, any Error>) {
        guard let operation = pending.removeValue(forKey: id) else { return }
        if setupID == id { setupID = nil }
        operation.timer.cancel()
        operation.continuation.resume(with: result)
    }

    private static func validate(_ configuration: Configuration) throws {
        guard (1...65_535).contains(configuration.port) else {
            throw TransportError.invalidConfiguration("Invalid port: \(configuration.port)")
        }
        guard configuration.timeout.isFinite, configuration.timeout > 0,
              configuration.connectionTimeout.isFinite, configuration.connectionTimeout > 0 else {
            throw TransportError.invalidConfiguration("Timeouts must be finite and positive")
        }
        guard configuration.maxRetries > 0 else {
            throw TransportError.invalidConfiguration("maxRetries must be positive")
        }
    }

    private static func duration(_ seconds: TimeInterval) -> Duration {
        // Saturate before floating-point conversion for very large finite inputs.
        // Covered by testConfigurationValidationPrecedesDriverStartAndDurationConversion.
        seconds >= Double(Int64.max) ? .seconds(Int64.max) : .seconds(seconds)
    }
}
