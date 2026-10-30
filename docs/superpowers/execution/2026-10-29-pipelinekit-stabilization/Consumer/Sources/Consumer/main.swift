import Foundation
import PipelineKitObservability
#if canImport(Darwin)
import Darwin
#endif

enum ConsumerFailure: Error {
    case unsupportedPlatform
    case unknownMode
    case socket(String, Int32)
    case missingReceipt
    case expectedFailure
}

func emit(_ fields: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

#if canImport(Darwin) && canImport(Network)
struct LoopbackListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw ConsumerFailure.socket("socket", errno) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw ConsumerFailure.socket("bind", errno) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw ConsumerFailure.socket("getsockname", errno) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw ConsumerFailure.socket("setsockopt", errno)
            }
            self.descriptor = descriptor
            self.port = Int(UInt16(bigEndian: address.sin_port))
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func acknowledge(_ expected: Data) throws {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == expected.count, Data(buffer.prefix(count)) == expected else {
            throw ConsumerFailure.missingReceipt
        }
    }

    func close() -> Int32 { Darwin.close(descriptor) }
}

func udpClose(expectSendFailure: Bool) async throws {
    let listener = try LoopbackListener()
    var listenerIsOpen = true
    defer { if listenerIsOpen { _ = listener.close() } }
    let transport = try await UDPTransport(configuration: .init(
        host: "127.0.0.1", port: listener.port, timeout: 2, connectionTimeout: 2, maxRetries: 1
    ))
    let mode = expectSendFailure ? "udp-failure-close" : "udp-close"
    try emit(["mode": mode, "phase": "ready", "port": listener.port])
    do {
        if expectSendFailure {
            // Exceeds the IPv4 UDP datagram maximum; Network reports EMSGSIZE.
            do {
                try await transport.send(Data(repeating: 0x61, count: 65_536))
                throw ConsumerFailure.expectedFailure
            } catch TransportError.connectionFailed(let message) {
                try emit(["mode": mode, "phase": "reported_send_failure", "error": message])
            }
        } else {
            let payload = Data("pipelinekit-stabilization-loopback:1|c".utf8)
            try await transport.send(payload)
            try listener.acknowledge(payload)
            try emit(["mode": mode, "phase": "receipt_acknowledged", "bytes": payload.count])
        }
    } catch {
        await transport.close()
        throw error
    }
    await transport.close()
    await transport.close()
    do {
        try await transport.send(Data("after-close".utf8))
        throw ConsumerFailure.expectedFailure
    } catch TransportError.transportClosed {}
    let closed = listener.close()
    listenerIsOpen = false
    guard closed == 0 else { throw ConsumerFailure.socket("close", errno) }
    try emit(["mode": mode, "phase": "listener_closed"])
    // A bounded observation window for Network's asynchronous cancellation callback.
    // The external run_check.py process-group watchdog owns overall liveness.
    try await Task.sleep(for: .seconds(2))
    try emit(["mode": mode, "phase": "closed_twice_and_survived_callback_window"])
}
#endif

do {
    let mode = CommandLine.arguments.dropFirst().first ?? "udp-close"
    #if canImport(Darwin) && canImport(Network)
    switch mode {
    case "udp-close": try await udpClose(expectSendFailure: false)
    case "udp-failure-close": try await udpClose(expectSendFailure: true)
    default: throw ConsumerFailure.unknownMode
    }
    #else
    throw ConsumerFailure.unsupportedPlatform
    #endif
} catch {
    try emit(["phase": "failed", "error": String(describing: error)])
    exit(1)
}
