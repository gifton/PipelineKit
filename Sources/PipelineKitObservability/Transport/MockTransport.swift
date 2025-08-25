import Foundation

/// Mock transport for testing that captures sent metrics without network I/O
public actor MockTransport: MetricsTransport {
    public struct Configuration: Sendable {
        public let shouldFail: Bool
        public let failureError: TransportError?
        public let captureMetrics: Bool
        public let simulateDelay: TimeInterval?
        
        public init(
            shouldFail: Bool = false,
            failureError: TransportError? = nil,
            captureMetrics: Bool = true,
            simulateDelay: TimeInterval? = nil
        ) {
            self.shouldFail = shouldFail
            self.failureError = failureError ?? .sendFailed("Mock failure")
            self.captureMetrics = captureMetrics
            self.simulateDelay = simulateDelay
        }
    }
    
    private let configuration: Configuration
    private var sentMetrics: [Data] = []
    private var sendCount: Int = 0
    private var isClosed: Bool = false
    
    public init(configuration: Configuration) async throws {
        self.configuration = configuration
    }
    
    public func send(_ data: Data) async throws {
        guard !isClosed else {
            throw TransportError.transportClosed
        }
        
        if configuration.shouldFail {
            throw configuration.failureError ?? TransportError.sendFailed("Mock transport configured to fail")
        }
        
        if let delay = configuration.simulateDelay {
            try await Task.sleep(for: .seconds(delay))
        }
        
        if configuration.captureMetrics {
            sentMetrics.append(data)
        }
        sendCount += 1
    }
    
    public func sendBatch(_ batch: [Data]) async throws {
        for data in batch {
            try await send(data)
        }
    }
    
    public func close() async {
        isClosed = true
        sentMetrics.removeAll()
    }
    
    // Test helper methods
    public func getSentMetrics() -> [Data] {
        return sentMetrics
    }
    
    public func getSendCount() -> Int {
        return sendCount
    }
    
    public func clearMetrics() {
        sentMetrics.removeAll()
        sendCount = 0
    }
    
    public func getMetricsAsStrings() -> [String] {
        return sentMetrics.compactMap { String(data: $0, encoding: .utf8) }
    }
}