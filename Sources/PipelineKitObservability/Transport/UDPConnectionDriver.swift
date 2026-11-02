import Foundation
#if canImport(Network)
import Network
#endif

internal enum UDPConnectionState: Sendable {
    case ready
    case failed(TransportError)
    case cancelled
}

internal protocol UDPConnectionDriver: Sendable {
    func start(onState: @escaping @Sendable (UDPConnectionState) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void)
    func cancel()
}

#if canImport(Network)
/// The unchecked boundary is confined to this Network adapter: `connection`,
/// `started`, and `cancelled` are accessed only on `queue` after initialization.
/// Every entry point enqueues work there, including handler installation/removal.
/// Replace this boundary when Network provides an actor-isolated connection API.
internal final class NetworkUDPConnectionDriver: UDPConnectionDriver, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PipelineKit.UDPConnection", qos: .utility)
    private let connection: NWConnection
    private var started = false
    private var cancelled = false

    init(configuration: UDPTransport.Configuration) {
        // UDPTransport validates the port before constructing this adapter.
        let port = NWEndpoint.Port(rawValue: UInt16(configuration.port))!
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: parameters)
    }

    func start(onState: @escaping @Sendable (UDPConnectionState) -> Void) {
        queue.async {
            guard !self.cancelled else { onState(.cancelled); return }
            guard !self.started else { return }
            self.started = true
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: onState(.ready)
                case .failed(let error): onState(.failed(.connectionFailed(error.localizedDescription)))
                case .cancelled: onState(.cancelled)
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void) {
        queue.async {
            guard self.started, !self.cancelled else { completion(.failure(.transportClosed)); return }
            self.connection.send(content: data, completion: .contentProcessed { error in
                guard let error else { completion(.success(())); return }
                // Only local transient resource/interruption failures are retryable.
                // Other reported errors invalidate the shared connection in UDPTransport.
                switch error {
                case .posix(.EAGAIN), .posix(.ENOBUFS), .posix(.EINTR):
                    completion(.failure(.sendFailed(error.localizedDescription)))
                default:
                    completion(.failure(.connectionFailed(error.localizedDescription)))
                }
            })
        }
    }

    func cancel() {
        queue.async {
            guard !self.cancelled else { return }
            self.cancelled = true
            self.connection.stateUpdateHandler = nil
            self.connection.cancel()
        }
    }
}
#endif
