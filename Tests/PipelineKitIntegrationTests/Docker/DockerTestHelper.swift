import Foundation
import XCTest

/// Helper for managing Docker services during integration tests
@available(macOS 13.0, *)
public actor DockerTestHelper {
    public static let shared = DockerTestHelper()
    
    private var servicesStarted = false
    
    /// Get the path to the docker directory using file URL
    private var dockerPath: String {
        let fileURL = URL(fileURLWithPath: #file)
        return fileURL
            .deletingLastPathComponent() // Remove DockerTestHelper.swift
            .deletingLastPathComponent() // Remove Docker/
            .deletingLastPathComponent() // Remove PipelineKitIntegrationTests/
            .deletingLastPathComponent() // Remove Tests/
            .appendingPathComponent("docker")
            .path
    }
    
    /// Start Docker services if not already running
    public func ensureServicesRunning() async throws {
        guard !servicesStarted else { return }
        
        // Check if services are already up
        let checkResult = try await runCommand("cd \(dockerPath) && make ps")
        if checkResult.contains("Up") {
            servicesStarted = true
            return
        }
        
        // Start services
        print("Starting Docker services...")
        _ = try await runCommand("cd \(dockerPath) && make up")
        servicesStarted = true
        
        // Additional wait for services to be fully ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    }
    
    /// Wait for a specific service to be ready
    public func waitForService(
        host: String = "localhost",
        port: Int,
        timeout: TimeInterval = 30,
        checkInterval: TimeInterval = 0.5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        
        while Date() < deadline {
            if await checkPort(host: host, port: port) {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }
        
        throw IntegrationTestError.serviceNotReady(service: "\(host):\(port)")
    }
    
    /// Check if a TCP port is open
    private func checkPort(host: String, port: Int) async -> Bool {
        let task = Task { () -> Bool in
            let sockfd = socket(AF_INET, SOCK_STREAM, 0)
            guard sockfd >= 0 else { return false }
            defer { close(sockfd) }
            
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    connect(sockfd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            
            return result == 0
        }
        
        return await task.value
    }
    
    /// Query OpenTelemetry Collector metrics endpoint
    public func queryOTelMetrics() async throws -> String {
        let url = URL(string: "http://localhost:8888/metrics")!
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw IntegrationTestError.invalidResponse
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    /// Run a shell command
    private func runCommand(_ command: String) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
            throw IntegrationTestError.commandFailed(output: output)
        }
        
        return output
    }
    
    /// Stop Docker services
    public func stopServices() async throws {
        guard servicesStarted else { return }
        
        print("Stopping Docker services...")
        _ = try await runCommand("cd \(dockerPath) && make down")
        servicesStarted = false
    }
    
    /// Get logs from a specific service
    public func getServiceLogs(service: String, lines: Int = 50) async throws -> String {
        return try await runCommand("cd \(dockerPath) && docker-compose logs --tail=\(lines) \(service)")
    }
}

/// Errors that can occur during integration testing
public enum IntegrationTestError: Error, LocalizedError {
    case serviceNotReady(service: String)
    case invalidResponse
    case commandFailed(output: String)
    
    public var errorDescription: String? {
        switch self {
        case .serviceNotReady(let service):
            return "Service \(service) did not become ready in time"
        case .invalidResponse:
            return "Received invalid response from service"
        case .commandFailed(let output):
            return "Command failed with output: \(output)"
        }
    }
}