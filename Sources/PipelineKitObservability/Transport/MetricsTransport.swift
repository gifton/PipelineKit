import Foundation

/// Protocol defining a transport mechanism for sending metrics
public protocol MetricsTransport: Sendable {
    /// Configuration type for this transport
    associatedtype Configuration: Sendable
    
    /// Initialize with configuration
    init(configuration: Configuration) async throws
    
    /// Send a single metric packet
    /// - Parameter data: The formatted metric data to send
    /// - Throws: Transport-specific errors
    func send(_ data: Data) async throws
    
    /// Send multiple metric packets in batch
    /// - Parameter batch: Array of formatted metric data packets
    /// - Throws: Transport-specific errors
    func sendBatch(_ batch: [Data]) async throws
    
    /// Close the transport and clean up resources
    func close() async
}

/// Error types for transport operations
public enum TransportError: Error, Sendable {
    case connectionFailed(String)
    case sendFailed(String)
    case timeout
    case invalidConfiguration(String)
    case transportClosed
}