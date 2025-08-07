import Foundation
import PipelineKitCore

/// Exports metrics to CSV format files.
///
/// CSVExporter writes metrics as comma-separated values with support for:
/// - Customizable headers and column ordering
/// - Proper escaping and quoting
/// - File rotation by size
/// - Efficient buffering
/// - Tag expansion to columns
public actor CSVExporter: MetricExporter {
    // MARK: - Properties
    
    private let configuration: CSVExportConfiguration
    private var fileHandle: FileHandle?
    private var currentFilePath: String
    private var currentFileSize: Int = 0
    private var buffer: [MetricDataPoint] = []
    private var flushTask: Task<Void, Never>?
    private var hasWrittenHeaders = false
    private var knownTags: Set<String> = []
    
    // Status tracking
    private var isActive = true
    private var successCount = 0
    private var failureCount = 0
    private var lastExportTime: Date?
    private var lastError: String?
    
    // Column definitions
    private let baseColumns = ["timestamp", "name", "value", "type"]
    
    // MARK: - Initialization
    
    public init(configuration: CSVExportConfiguration) async throws {
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
        
        // Track tags for dynamic columns
        metric.tags.keys.forEach { knownTags.insert($0) }
        
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
        
        // Track all tags
        for metric in metrics {
            metric.tags.keys.forEach { knownTags.insert($0) }
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
        // Convert aggregated metrics to CSV rows
        for aggregated in metrics {
            let baseRow: [String: String] = [
                "timestamp": formatDate(aggregated.timestamp),
                "name": aggregated.name,
                "type": aggregated.type.rawValue,
                "window": "\(Int(aggregated.window.duration))s"
            ]
            
            // Add statistics based on type
            var statRows: [[String: String]] = []
            
            switch aggregated.statistics {
            case .basic(let stats):
                statRows.append(baseRow.merging([
                    "statistic": "count",
                    "value": "\(stats.count)"
                ]) { _, new in new })
                statRows.append(baseRow.merging([
                    "statistic": "min",
                    "value": formatDouble(stats.min)
                ]) { _, new in new })
                statRows.append(baseRow.merging([
                    "statistic": "max",
                    "value": formatDouble(stats.max)
                ]) { _, new in new })
                statRows.append(baseRow.merging([
                    "statistic": "mean",
                    "value": formatDouble(stats.mean)
                ]) { _, new in new })
                
            case .counter(let stats):
                statRows.append(baseRow.merging([
                    "statistic": "rate",
                    "value": formatDouble(stats.rate)
                ]) { _, new in new })
                statRows.append(baseRow.merging([
                    "statistic": "increase",
                    "value": formatDouble(stats.increase)
                ]) { _, new in new })
                
            case .histogram(let stats):
                let percentiles = [
                    ("p50", stats.p50),
                    ("p90", stats.p90),
                    ("p95", stats.p95),
                    ("p99", stats.p99),
                    ("p999", stats.p999)
                ]
                
                for (name, value) in percentiles {
                    statRows.append(baseRow.merging([
                        "statistic": name,
                        "value": formatDouble(value)
                    ]) { _, new in new })
                }
            }
            
            // Write rows
            for row in statRows {
                let line = formatCSVLine(row, columns: ["timestamp", "name", "type", "window", "statistic", "value"])
                try await writeData(Data((line + configuration.lineEnding.rawValue).utf8))
            }
        }
    }
    
    public func flush() async throws {
        guard !buffer.isEmpty else { return }
        
        let toWrite = buffer
        buffer.removeAll(keepingCapacity: true)
        
        // Write headers if needed
        if !hasWrittenHeaders && configuration.includeHeaders {
            try await writeHeaders()
        }
        
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
            if let handle = fileHandle {
                try handle.seekToEnd()
                currentFileSize = Int(try handle.offset())
            } else {
                currentFileSize = 0
            }
            hasWrittenHeaders = currentFileSize > 0
        } else {
            FileManager.default.createFile(atPath: currentFilePath, contents: nil)
            fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: currentFilePath))
            currentFileSize = 0
            hasWrittenHeaders = false
        }
    }
    
    private func writeHeaders() async throws {
        let columns = configuration.headers ?? (baseColumns + knownTags.sorted())
        let headerLine = columns.map { escapeCSVField($0) }.joined(separator: configuration.separator)
        
        try await writeData(Data((headerLine + configuration.lineEnding.rawValue).utf8))
        hasWrittenHeaders = true
    }
    
    private func writeMetric(_ metric: MetricDataPoint) async throws {
        // Build row data
        var rowData: [String: String] = [
            "timestamp": formatDate(metric.timestamp),
            "name": metric.name,
            "value": formatDouble(metric.value),
            "type": metric.type.rawValue
        ]
        
        // Add tags
        for (key, value) in metric.tags {
            rowData[key] = value
        }
        
        // Format as CSV line
        let columns = configuration.headers ?? (baseColumns + knownTags.sorted())
        let line = formatCSVLine(rowData, columns: columns)
        
        try await writeData(Data((line + configuration.lineEnding.rawValue).utf8))
        successCount += 1
        lastExportTime = Date()
    }
    
    private func formatCSVLine(_ data: [String: String], columns: [String]) -> String {
        columns.map { column in
            let value = data[column] ?? ""
            return escapeCSVField(value)
        }.joined(separator: configuration.separator)
    }
    
    private func escapeCSVField(_ field: String) -> String {
        // Check if field needs quoting
        let needsQuoting = configuration.quoteAll ||
            field.contains(configuration.separator) ||
            field.contains(configuration.quoteCharacter) ||
            field.contains("\n") ||
            field.contains("\r")
        
        if needsQuoting {
            // Escape quotes by doubling them
            let escaped = field.replacingOccurrences(
                of: configuration.quoteCharacter,
                with: configuration.quoteCharacter + configuration.quoteCharacter
            )
            return configuration.quoteCharacter + escaped + configuration.quoteCharacter
        }
        
        return field
    }
    
    private func writeData(_ data: Data) async throws {
        guard let handle = fileHandle else {
            throw PipelineError.export(reason: .ioError("Exporter is not configured"))
        }
        
        do {
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
        
        // Reset headers flag for new file
        hasWrittenHeaders = false
    }
    
    private func compressFile(at url: URL) async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        task.arguments = ["-9", url.path]
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
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
    
    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    
    private func formatDouble(_ value: Double) -> String {
        return String(format: "%.\(configuration.fileConfig.bufferSize > 0 ? 3 : 6)f", value)
    }
    
    deinit {
        flushTask?.cancel()
    }
}
