import Foundation
#if canImport(Network)
import Network
#endif

/// UDP transport for sending metrics over the network
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
    
    private let configuration: Configuration
    
    #if canImport(Network)
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "UDPTransport", qos: .utility)
    #endif
    
    private var isClosed: Bool = false
    
    public init(configuration: Configuration) async throws {
        self.configuration = configuration
        
        #if canImport(Network)
        // Validate port
        guard configuration.port > 0 && configuration.port <= 65535 else {
            throw TransportError.invalidConfiguration("Invalid port: \(configuration.port)")
        }
        
        // Create connection
        let host = NWEndpoint.Host(configuration.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(configuration.port))
        
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        connection = NWConnection(host: host, port: port, using: params)
        
        // Set up connection with timeout
        try await withTimeout(seconds: configuration.connectionTimeout) { [self] in
            try await self.setupConnection()
        }
        #endif
    }
    
    #if canImport(Network)
    private func setupConnection() async throws {
        guard let connection = connection else {
            throw TransportError.connectionFailed("No connection available")
        }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    // Log error but don't fail - UDP is connectionless
                    print("UDP connection state failed: \(error)")
                    continuation.resume()
                case .cancelled:
                    continuation.resume()
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
        }
    }
    #endif
    
    public func send(_ data: Data) async throws {
        guard !isClosed else {
            throw TransportError.transportClosed
        }
        
        #if canImport(Network)
        guard let connection = connection else {
            throw TransportError.connectionFailed("No connection available")
        }
        
        // Send with timeout and retries
        var lastError: Error?
        
        for attempt in 0..<configuration.maxRetries {
            do {
                try await withTimeout(seconds: configuration.timeout) {
                    try await self.sendData(data, on: connection)
                }
                return  // Success
            } catch {
                lastError = error
                if attempt < configuration.maxRetries - 1 {
                    // Wait before retry (exponential backoff)
                    try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
                }
            }
        }
        
        // All retries failed
        if let error = lastError as? TransportError {
            throw error
        } else {
            throw TransportError.sendFailed("Failed after \(configuration.maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown error")")
        }
        #else
        // Fallback for non-Network platforms
        throw TransportError.connectionFailed("Network framework not available")
        #endif
    }
    
    #if canImport(Network)
    private func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: TransportError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
    #endif
    
    public func sendBatch(_ batch: [Data]) async throws {
        // For UDP, we can send packets in parallel since they're independent
        try await withThrowingTaskGroup(of: Void.self) { group in
            for data in batch {
                group.addTask {
                    try await self.send(data)
                }
            }
            
            // Collect any errors
            do {
                for try await _ in group {
                    // Process completions
                }
            } catch {
                // Cancel remaining tasks on first error
                group.cancelAll()
                throw error
            }
        }
    }
    
    public func close() async {
        isClosed = true
        
        #if canImport(Network)
        connection?.cancel()
        connection = nil
        #endif
    }
    
    private func withTimeout<T: Sendable>(
        seconds timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TransportError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}