import Foundation
import PipelineKitCore

/// Exports metrics to JSON format files.
///
/// JSONExporter writes metrics as JSON arrays to files with support for:
/// - Pretty printing or compact format
/// - Configurable timestamp formats
/// - File rotation by size
/// - Streaming writes for efficiency
/// - Atomic file operations
public actor JSONExporter: MetricExporter {
    // MARK: - Properties
    
    private let configuration: JSONExportConfiguration
    private var fileHandle: FileHandle?
    private var currentFilePath: String
    private var currentFileSize: Int = 0
    private var buffer: [MetricDataPoint] = []
    private var flushTask: Task<Void, Never>?
    
    // Status tracking
    private var isActive = true
    private var successCount = 0
    private var failureCount = 0
    private var lastExportTime: Date?
    private var lastError: String?
    
    // JSON formatting
    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        if configuration.prettyPrint {
            encoder.outputFormatting = [.prettyPrinted]
            if configuration.sortKeys {
                encoder.outputFormatting.insert(.sortedKeys)
            }
        }
        
        switch configuration.dateFormat {
        case .iso8601:
            encoder.dateEncodingStrategy = .iso8601
        case .unix:
            encoder.dateEncodingStrategy = .secondsSince1970
        case .unixMillis:
            encoder.dateEncodingStrategy = .millisecondsSince1970
        case .custom:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            encoder.dateEncodingStrategy = .formatted(formatter)
        }
        
        return encoder
    }()
    
    // MARK: - Initialization
    
    public init(configuration: JSONExportConfiguration) async throws {
        self.configuration = configuration
        self.currentFilePath = configuration.fileConfig.path
        
        // Ensure directory exists
        let directory = URL(fileURLWithPath: configuration.fileConfig.path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Open file for writing
        try await openFile()
        
        // Start flush timer if not real-time
        if !configuration.fileConfig.realTimeExport {
            startFlushTimer()
        }
    }
    
    // MARK: - MetricExporter Protocol
    
    public func export(_ metric: MetricDataPoint) async throws {
        guard isActive else {
            throw PipelineError.export(reason: .ioError("Exporter is shutting down"))
        }
        
        if configuration.fileConfig.realTimeExport {
            try await writeMetric(metric)
        } else {
            buffer.append(metric)
            
            if buffer.count >= configuration.fileConfig.bufferSize {
                try await flush()
            }
        }
    }
    
    public func exportBatch(_ metrics: [MetricDataPoint]) async throws {
        guard isActive else {
            throw PipelineError.export(reason: .ioError("Exporter is shutting down"))
        }
        
        if configuration.fileConfig.realTimeExport {
            for metric in metrics {
                try await writeMetric(metric)
            }
        } else {
            buffer.append(contentsOf: metrics)
            
            if buffer.count >= configuration.fileConfig.bufferSize {
                try await flush()
            }
        }
    }
    
    public func exportAggregated(_ metrics: [AggregatedMetrics]) async throws {
        // Convert to JSON representation
        let jsonMetrics = metrics.map { aggregated -> [String: Any] in
            var json: [String: Any] = [
                "name": aggregated.name,
                "type": aggregated.type.rawValue,
                "timestamp": formatDate(aggregated.timestamp),
                "window": [
                    "duration": aggregated.window.duration,
                    "start": formatDate(aggregated.window.startTime),
                    "end": formatDate(aggregated.window.endTime)
                ]
            ]
            
            // Add statistics based on type
            switch aggregated.statistics {
            case .basic(let stats):
                json["statistics"] = [
                    "count": stats.count,
                    "min": formatDouble(stats.min),
                    "max": formatDouble(stats.max),
                    "mean": formatDouble(stats.mean),
                    "sum": formatDouble(stats.sum)
                ]
                
            case .counter(let stats):
                json["statistics"] = [
                    "count": stats.count,
                    "rate": formatDouble(stats.rate),
                    "increase": formatDouble(stats.increase)
                ]
                
            case .histogram(let stats):
                json["statistics"] = [
                    "count": stats.count,
                    "min": formatDouble(stats.min),
                    "max": formatDouble(stats.max),
                    "mean": formatDouble(stats.mean),
                    "p50": formatDouble(stats.p50),
                    "p90": formatDouble(stats.p90),
                    "p95": formatDouble(stats.p95),
                    "p99": formatDouble(stats.p99),
                    "p999": formatDouble(stats.p999)
                ]
            }
            
            if !aggregated.tags.isEmpty {
                json["tags"] = aggregated.tags
            }
            
            return json
        }
        
        // Write as JSON array
        let data = try JSONSerialization.data(
            withJSONObject: jsonMetrics,
            options: configuration.prettyPrint ? .prettyPrinted : []
        )
        
        try await writeData(data)
    }
    
    public func flush() async throws {
        guard !buffer.isEmpty else { return }
        
        let toWrite = buffer
        buffer.removeAll(keepingCapacity: true)
        
        for metric in toWrite {
            try await writeMetric(metric)
        }
    }
    
    public func shutdown() async {
        isActive = false
        flushTask?.cancel()
        
        // Final flush
        try? await flush()
        
        // Close file
        try? fileHandle?.close()
        fileHandle = nil
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
    
    private func openFile() async throws {
        // Close existing handle
        if let handle = fileHandle {
            try handle.close()
        }
        
        // Create or open file
        if FileManager.default.fileExists(atPath: currentFilePath) {
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: currentFilePath))
            try fileHandle?.seekToEnd()
            currentFileSize = Int(try fileHandle?.offset() ?? 0)
        } else {
            FileManager.default.createFile(atPath: currentFilePath, contents: nil)
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: currentFilePath))
            currentFileSize = 0
            
            // Write opening bracket for JSON array
            fileHandle?.write(Data("[\n".utf8))
            currentFileSize += 2
        }
    }
    
    private func writeMetric(_ metric: MetricDataPoint) async throws {
        // Create JSON representation
        let json: [String: Any] = [
            "timestamp": formatDate(metric.timestamp),
            "name": metric.name,
            "value": formatDouble(metric.value),
            "type": metric.type.rawValue,
            "tags": metric.tags.isEmpty ? nil : metric.tags
        ].compactMapValues { $0 }
        
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: configuration.prettyPrint ? .prettyPrinted : []
        )
        
        try await writeData(data)
        successCount += 1
        lastExportTime = Date()
    }
    
    private func writeData(_ data: Data) async throws {
        guard let handle = fileHandle else {
            throw PipelineError.export(reason: .ioError("Exporter is not configured"))
        }
        
        do {
            // Add comma if not first entry
            if currentFileSize > 2 { // More than just "[\n"
                handle.write(Data(",\n".utf8))
                currentFileSize += 2
            }
            
            handle.write(data)
            currentFileSize += data.count
            
            // Check for rotation
            if currentFileSize >= configuration.fileConfig.maxFileSize {
                try await rotateFile()
            }
        } catch {
            failureCount += 1
            lastError = error.localizedDescription
            throw PipelineError.export(reason: .ioError(error.localizedDescription))
        }
    }
    
    private func rotateFile() async throws {
        // Close current file with closing bracket
        fileHandle?.write(Data("\n]".utf8))
        try fileHandle?.close()
        
        // Rotate files
        let baseURL = URL(fileURLWithPath: currentFilePath)
        let directory = baseURL.deletingLastPathComponent()
        let basename = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        
        // Shift existing files
        for i in (1..<configuration.fileConfig.maxFiles).reversed() {
            let oldPath = directory.appendingPathComponent("\(basename).\(i).\(ext)")
            let newPath = directory.appendingPathComponent("\(basename).\(i + 1).\(ext)")
            
            if FileManager.default.fileExists(atPath: oldPath.path) {
                try? FileManager.default.removeItem(at: newPath)
                try? FileManager.default.moveItem(at: oldPath, to: newPath)
            }
        }
        
        // Move current to .1
        let rotatedPath = directory.appendingPathComponent("\(basename).1.\(ext)")
        try? FileManager.default.removeItem(at: rotatedPath)
        try FileManager.default.moveItem(at: baseURL, to: rotatedPath)
        
        // Compress if configured
        if configuration.fileConfig.compressRotated {
            Task {
                await compressFile(at: rotatedPath)
            }
        }
        
        // Open new file
        try await openFile()
    }
    
    private func compressFile(at url: URL) async {
        // Simple gzip compression
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        task.arguments = ["-9", url.path]
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Log compression failure but don't fail export
            print("Failed to compress rotated file: \(error)")
        }
    }
    
    private func startFlushTimer() {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(configuration.fileConfig.flushInterval * 1_000_000_000))
                
                if isActive {
                    try? await flush()
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> Any {
        switch configuration.dateFormat {
        case .iso8601:
            return ISO8601DateFormatter().string(from: date)
        case .unix:
            return Int(date.timeIntervalSince1970)
        case .unixMillis:
            return Int(date.timeIntervalSince1970 * 1000)
        case .custom:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            return formatter.string(from: date)
        }
    }
    
    private func formatDouble(_ value: Double) -> Double {
        let multiplier = pow(10.0, Double(configuration.decimalPlaces))
        return round(value * multiplier) / multiplier
    }
    
    deinit {
        flushTask?.cancel()
    }
}