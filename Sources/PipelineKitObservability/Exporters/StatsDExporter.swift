import Foundation
import PipelineKitCore
#if canImport(Network)
import Network
#endif

/// Exports metrics in StatsD protocol format.
///
/// StatsDExporter sends metrics to StatsD-compatible servers using UDP.
/// It supports the basic StatsD metric types and tags (DogStatsD format).
///
/// ## Features
/// - UDP transport for low-overhead metrics
/// - Automatic metric type mapping
/// - Tag support (DogStatsD format)
/// - Configurable sampling rates
/// - Batch sending for efficiency
///
/// ## Metric Type Mapping
/// - gauge → gauge (g)
/// - counter → counter (c)
/// - histogram/timer → timing (ms)
///
/// ## Example
/// ```swift
/// let exporter = try await StatsDExporter(
///     configuration: StatsDExportConfiguration(
///         host: "localhost",
///         port: 8125
///     )
/// )
/// ```
public actor StatsDExporter: MetricExporter {
    // MARK: - Properties
    
    private let configuration: StatsDExportConfiguration
    private var buffer: [String] = []
    private var flushTask: Task<Void, Never>?
    
    #if canImport(Network)
    private var connection: NWConnection?
    #endif
    
    // Status tracking
    private var isActive = true
    private var successCount = 0
    private var failureCount = 0
    private var lastExportTime: Date?
    private var lastError: String?
    
    // MARK: - Initialization
    
    public init(configuration: StatsDExportConfiguration) async throws {
        self.configuration = configuration
        
        #if canImport(Network)
        // Create UDP connection
        let host = NWEndpoint.Host(configuration.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(configuration.port))
        
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        connection = NWConnection(host: host, port: port, using: params)
        connection?.start(queue: .global())
        
        // Wait for connection to be ready
        await waitForConnection()
        #else
        throw PipelineError.export(reason: .formatNotSupported("StatsD requires Network framework"))
        #endif
        
        // Start flush timer if not in real-time mode
        if !configuration.realTimeExport {
            startFlushTimer()
        }
    }
    
    deinit {
        flushTask?.cancel()
        #if canImport(Network)
        connection?.cancel()
        #endif
    }
    
    // MARK: - MetricExporter Protocol
    
    public func export(_ metric: MetricDataPoint) async throws {
        guard isActive else {
            throw PipelineError.export(reason: .exporterClosed)
        }
        
        let statsdLine = formatMetric(metric)
        
        if configuration.realTimeExport {
            // Send immediately
            try await send(statsdLine)
        } else {
            // Buffer for batch sending
            buffer.append(statsdLine)
            
            // Flush if buffer is full
            if buffer.count >= configuration.bufferSize {
                try await flush()
            }
        }
    }
    
    public func exportBatch(_ metrics: [MetricDataPoint]) async throws {
        guard isActive else {
            throw PipelineError.export(reason: .exporterClosed)
        }
        
        guard !metrics.isEmpty else { return }
        
        let lines = metrics.map { formatMetric($0) }
        
        if configuration.realTimeExport {
            // Send all immediately
            for line in lines {
                try await send(line)
            }
        } else {
            // Add to buffer
            buffer.append(contentsOf: lines)
            
            // Flush if needed
            if buffer.count >= configuration.bufferSize {
                try await flush()
            }
        }
    }
    
    public func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
        // Convert aggregated metrics to StatsD format
        var dataPoints: [MetricDataPoint] = []
        
        for aggregated in metrics {
            let baseTags = aggregated.tags.merging([
                "window": "\(Int(aggregated.window.duration))s"
            ]) { _, new in new }
            
            switch aggregated.statistics {
            case .basic(let stats):
                // Send current value as gauge
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: aggregated.name,
                    value: stats.mean,
                    type: .gauge,
                    tags: baseTags
                ))
                
            case .counter(let stats):
                // Send increase as counter
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: aggregated.name,
                    value: stats.increase,
                    type: .counter,
                    tags: baseTags
                ))
                
            case .histogram(let stats):
                // Send percentiles as timing metrics
                dataPoints.append(MetricDataPoint(
                    timestamp: aggregated.timestamp,
                    name: "\(aggregated.name).p95",
                    value: stats.p95 * 1000, // Convert to milliseconds
                    type: .timer,
                    tags: baseTags
                ))
            }
        }
        
        try await exportBatch(dataPoints)
    }
    
    public func flush() async throws {
        guard !buffer.isEmpty else { return }
        
        let linesToSend = buffer
        buffer.removeAll()
        
        // Send all buffered metrics
        for line in linesToSend {
            try await send(line)
        }
    }
    
    public func shutdown() async {
        isActive = false
        flushTask?.cancel()
        
        // Try to flush remaining metrics
        try? await flush()
        
        #if canImport(Network)
        connection?.cancel()
        connection = nil
        #endif
    }
    
    public var status: ExporterStatus {
        ExporterStatus(
            isActive: isActive,
            queueDepth: buffer.count,
            successCount: successCount,
            failureCount: failureCount,
            lastExportTime: lastExportTime,
            lastError: lastError
        )
    }
    
    // MARK: - Private Methods
    
    private func startFlushTimer() {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.flushInterval * 1_000_000_000))
                try? await flush()
            }
        }
    }
    
    #if canImport(Network)
    private func waitForConnection() async {
        guard let connection = connection else { return }
        
        await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(_):
                    Task { @MainActor in
                        // Note: We can't access self here due to actor isolation
                        // The error will be handled elsewhere
                    }
                    continuation.resume()
                default:
                    break
                }
            }
        }
    }
    #endif
    
    private func setLastError(_ error: String) {
        self.lastError = error
    }
    
    private func incrementSuccessCount() {
        self.successCount += 1
    }
    
    private func incrementFailureCount() {
        self.failureCount += 1
    }
    
    private func setLastExportTime(_ time: Date) {
        self.lastExportTime = time
    }
    
    private func send(_ line: String) async throws {
        #if canImport(Network)
        guard let connection = connection else {
            throw PipelineError.export(reason: .ioError("No connection"))
        }
        
        guard let data = line.data(using: .utf8) else {
            throw PipelineError.export(reason: .invalidData("Failed to encode metric"))
        }
        
        // Apply sampling rate
        if configuration.sampleRate < 1.0 {
            let random = Double.random(in: 0..<1)
            if random > configuration.sampleRate {
                return // Skip this metric based on sampling
            }
        }
        
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    Task {
                        await self.incrementFailureCount()
                        await self.setLastError(error.localizedDescription)
                    }
                } else {
                    Task {
                        await self.incrementSuccessCount()
                        await self.setLastExportTime(Date())
                    }
                }
                continuation.resume()
            })
        }
        #else
        throw PipelineError.export(reason: .formatNotSupported("StatsD requires Network framework"))
        #endif
    }
    
    private func formatMetric(_ metric: MetricDataPoint) -> String {
        var line = ""
        
        // Metric name with prefix
        let metricName = configuration.prefix + sanitizeMetricName(metric.name)
        
        // Format based on metric type
        switch metric.type {
        case .gauge:
            line = "\(metricName):\(metric.value)|g"
            
        case .counter:
            line = "\(metricName):\(Int(metric.value))|c"
            
        case .histogram, .timer:
            // Convert to milliseconds for timing metrics
            let milliseconds = metric.value * 1000
            line = "\(metricName):\(Int(milliseconds))|ms"
        }
        
        // Add sampling rate if applicable
        if configuration.sampleRate < 1.0 {
            line += "|@\(configuration.sampleRate)"
        }
        
        // Add tags in DogStatsD format if enabled
        if configuration.enableTags && !metric.tags.isEmpty {
            let tagString = metric.tags
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            line += "|#\(tagString)"
        }
        
        // Add global tags
        if !configuration.globalTags.isEmpty {
            let globalTagString = configuration.globalTags
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            
            if line.contains("|#") {
                line += ",\(globalTagString)"
            } else {
                line += "|#\(globalTagString)"
            }
        }
        
        return line
    }
    
    private func sanitizeMetricName(_ name: String) -> String {
        // StatsD metric names should not contain : | @ or #
        return name
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "@", with: "_")
            .replacingOccurrences(of: "#", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
