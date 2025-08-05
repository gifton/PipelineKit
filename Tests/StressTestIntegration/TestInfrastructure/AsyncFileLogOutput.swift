import Foundation

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*

/// Asynchronous file output for non-blocking log writes.
///
/// This implementation uses async/await and file handles for better performance
/// under heavy logging loads, preventing blocking I/O operations.
public actor AsyncFileLogOutput: LogOutput {
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.pipelinekit.async-file-log", qos: .utility)
    
    /// Maximum buffer size before forcing a flush (in bytes)
    private let maxBufferSize: Int
    
    /// Current buffer of pending writes
    private var buffer: Data = Data()
    
    /// Flush task for periodic writes
    private var flushTask: Task<Void, Never>?
    
    public init(fileURL: URL, maxBufferSize: Int = 4096) throws {
        self.fileURL = fileURL
        self.maxBufferSize = maxBufferSize
        
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
        
        // Start periodic flush task
        startPeriodicFlush()
    }
    
    deinit {
        flushTask?.cancel()
        // Synchronously flush remaining buffer
        if !buffer.isEmpty {
            try? fileHandle?.write(contentsOf: buffer)
        }
        fileHandle?.closeFile()
    }
    
    /// Write a log message asynchronously
    public func write(_ message: String) {
        Task {
            await self.writeAsync(message)
        }
    }
    
    /// Internal async write implementation
    private func writeAsync(_ message: String) async {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        
        buffer.append(data)
        
        // Flush if buffer exceeds max size
        if buffer.count >= maxBufferSize {
            await flush()
        }
    }
    
    /// Flush buffer to disk
    private func flush() async {
        guard !buffer.isEmpty else { return }
        
        let dataToWrite = buffer
        buffer = Data()
        
        // Perform async write
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                do {
                    try self?.fileHandle?.write(contentsOf: dataToWrite)
                    self?.fileHandle?.synchronizeFile()
                } catch {
                    // Log error to console as fallback
                    print("[AsyncFileLogOutput] Write error: \(error)")
                }
                continuation.resume()
            }
        }
    }
    
    /// Start periodic flush task
    private func startPeriodicFlush() {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await flush()
            }
        }
    }
    
    /// Force immediate flush
    public func forceFlush() async {
        await flush()
    }
}

/// Enhanced file output with rotation support
public actor RotatingFileLogOutput: LogOutput {
    private let baseURL: URL
    private let maxFileSize: Int
    private let maxFiles: Int
    private var currentOutput: AsyncFileLogOutput?
    private var currentFileSize: Int = 0
    
    public init(
        baseURL: URL,
        maxFileSize: Int = 10_485_760, // 10MB
        maxFiles: Int = 5
    ) throws {
        self.baseURL = baseURL
        self.maxFileSize = maxFileSize
        self.maxFiles = maxFiles
        
        // Initialize with current log file
        self.currentOutput = try AsyncFileLogOutput(fileURL: baseURL)
        self.currentFileSize = try getCurrentFileSize()
    }
    
    public func write(_ message: String) {
        Task {
            await writeWithRotation(message)
        }
    }
    
    private func writeWithRotation(_ message: String) async {
        let messageSize = message.utf8.count + 1 // +1 for newline
        
        // Check if rotation is needed
        if currentFileSize + messageSize > maxFileSize {
            await rotate()
        }
        
        currentOutput?.write(message)
        currentFileSize += messageSize
    }
    
    private func rotate() async {
        // Flush current file
        await currentOutput?.forceFlush()
        
        // Rotate existing files
        for i in (1..<maxFiles).reversed() {
            let oldURL = rotatedFileURL(index: i - 1)
            let newURL = rotatedFileURL(index: i)
            
            if FileManager.default.fileExists(atPath: oldURL.path) {
                try? FileManager.default.moveItem(at: oldURL, to: newURL)
            }
        }
        
        // Move current file to .1
        if FileManager.default.fileExists(atPath: baseURL.path) {
            try? FileManager.default.moveItem(at: baseURL, to: rotatedFileURL(index: 1))
        }
        
        // Create new output
        currentOutput = try? AsyncFileLogOutput(fileURL: baseURL)
        currentFileSize = 0
    }
    
    private func rotatedFileURL(index: Int) -> URL {
        let filename = baseURL.lastPathComponent
        let directory = baseURL.deletingLastPathComponent()
        let rotatedName = "\(filename).\(index)"
        return directory.appendingPathComponent(rotatedName)
    }
    
    private func getCurrentFileSize() throws -> Int {
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return 0
        }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: baseURL.path)
        return (attributes[.size] as? Int) ?? 0
    }
}
*/

// Placeholder types to prevent compilation errors
public actor AsyncFileLogOutput {}
public actor RotatingFileLogOutput {}
