import Foundation
import PipelineKitCore

/// Protocol for exporting metrics to various backends.
///
/// MetricExporter defines a minimal interface that all exporters must implement.
/// The protocol is designed to be simple yet flexible enough for different export formats.
public protocol MetricExporter: Sendable {
    /// Export a batch of metrics.
    ///
    /// - Parameter metrics: Array of metric snapshots to export
    /// - Throws: Export-specific errors (network, serialization, etc.)
    ///
    /// Note: Implementations should handle batching internally if needed.
    /// For pull-based systems (like Prometheus), this might store metrics.
    /// For push-based systems (like OTLP), this sends them immediately.
    func export(_ metrics: [MetricSnapshot]) async throws

    /// Flush any buffered metrics.
    ///
    /// Forces immediate export of any buffered data.
    /// For unbuffered exporters, this can be a no-op.
    func flush() async throws

    /// Shutdown the exporter gracefully.
    ///
    /// Clean up resources, flush remaining data, close connections.
    /// After shutdown, the exporter should not accept new metrics.
    func shutdown() async
}

// MARK: - Default Implementations

public extension MetricExporter {
    /// Default flush implementation (no-op).
    func flush() async throws {
        // No-op by default
    }

    /// Default shutdown implementation.
    func shutdown() async {
        try? await flush()
    }
}

// MARK: - Batching Support

/// Policy for handling buffer overflow in batching exporters.
public enum BufferPolicy: Sendable {
    case dropOldest    // Drop oldest metrics when buffer is full
    case dropNewest    // Drop newest metrics when buffer is full  
    case throwError    // Throw error when buffer is full
}

// Constants for time conversion
private let nanosecondsPerSecond: Double = 1_000_000_000

/// A wrapper that adds batching to any exporter.
///
/// BatchingExporter accumulates metrics and exports them in batches
/// based on size or time limits, reducing overhead for push-based exporters.
public actor BatchingExporter<E: MetricExporter>: MetricExporter {
    private let underlying: E
    private var buffer: [MetricSnapshot] = []
    private let maxBatchSize: Int
    private let maxBufferSize: Int
    private let bufferPolicy: BufferPolicy
    private let maxBatchAge: TimeInterval
    private var lastFlush = ContinuousClock.now
    private var flushTask: Task<Void, Never>?

    // Self-instrumentation
    private var exportsTotal: Int = 0
    private var exportFailuresTotal: Int = 0
    private var metricsExportedTotal: Int = 0
    private var metricsDroppedTotal: Int = 0

    public init(
        underlying: E,
        maxBatchSize: Int = 100,
        maxBufferSize: Int = 10_000,
        bufferPolicy: BufferPolicy = .dropOldest,
        maxBatchAge: TimeInterval = 10.0,
        autostart: Bool = true
    ) async {
        self.underlying = underlying
        self.maxBatchSize = maxBatchSize
        self.maxBufferSize = maxBufferSize
        self.bufferPolicy = bufferPolicy
        self.maxBatchAge = maxBatchAge
        self.flushTask = nil

        if autostart {
            await start()
        }
    }

    /// Start the periodic flush timer.
    /// Thread-safe due to actor isolation.
    public func start() async {
        guard flushTask == nil else { return }

        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                try? await Task.sleep(nanoseconds: UInt64(self.maxBatchAge * nanosecondsPerSecond))
                try? await self.flushIfNeeded()
            }
        }
    }

    deinit {
        flushTask?.cancel()
    }

    public func export(_ metrics: [MetricSnapshot]) async throws {
        // Handle buffer overflow based on policy
        let totalAfterAdd = buffer.count + metrics.count

        if totalAfterAdd > maxBufferSize {
            switch bufferPolicy {
            case .dropOldest:
                let toRemove = totalAfterAdd - maxBufferSize
                if toRemove >= buffer.count {
                    metricsDroppedTotal += buffer.count
                    buffer.removeAll()
                } else {
                    metricsDroppedTotal += toRemove
                    buffer.removeFirst(toRemove)
                }
            case .dropNewest:
                // Don't add new metrics if buffer is full
                let available = maxBufferSize - buffer.count
                if available > 0 {
                    buffer.append(contentsOf: metrics.prefix(available))
                    metricsDroppedTotal += max(0, metrics.count - available)
                } else {
                    metricsDroppedTotal += metrics.count
                }
            case .throwError:
                throw MetricExporterError.bufferOverflow(current: buffer.count, attempted: metrics.count, max: maxBufferSize)
            }
        } else {
            buffer.append(contentsOf: metrics)
        }

        if buffer.count >= maxBatchSize {
            try await flush()
        }
    }

    public func flush() async throws {
        guard !buffer.isEmpty else { return }

        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        lastFlush = ContinuousClock.now

        do {
            try await underlying.export(batch)
            exportsTotal += 1
            metricsExportedTotal += batch.count
        } catch {
            exportFailuresTotal += 1
            throw error
        }
    }

    public func shutdown() async {
        flushTask?.cancel()
        try? await flush()
        await underlying.shutdown()
    }

    /// Get current instrumentation metrics.
    public func getStats() -> ExporterStats {
        ExporterStats(
            exportsTotal: exportsTotal,
            exportFailuresTotal: exportFailuresTotal,
            metricsExportedTotal: metricsExportedTotal,
            metricsDroppedTotal: metricsDroppedTotal,
            currentBufferSize: buffer.count
        )
    }

    private func flushIfNeeded() async throws {
        let elapsed = lastFlush.duration(to: .now)
        if elapsed >= .seconds(maxBatchAge) && !buffer.isEmpty {
            try await flush()
        }
    }
}

// MARK: - Stream Support

/// Extension to support streaming metrics.
public extension MetricExporter {
    /// Export a stream of metrics with automatic batching.
    ///
    /// - Parameter stream: Async stream of metric snapshots
    /// - Parameter batchSize: Number of metrics to batch before exporting
    func exportStream(
        _ stream: AsyncStream<MetricSnapshot>,
        batchSize: Int = 100
    ) async throws {
        var buffer: [MetricSnapshot] = []

        for await metric in stream {
            buffer.append(metric)

            if buffer.count >= batchSize {
                try await export(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // Export any remaining metrics
        if !buffer.isEmpty {
            try await export(buffer)
        }
    }
}

// MARK: - Multi-Exporter Support

/// An exporter that forwards metrics to multiple underlying exporters.
///
/// Useful for sending metrics to multiple backends simultaneously.
/// Uses fail-fast strategy: if any exporter fails, all remaining tasks are cancelled.
public struct MultiExporter: MetricExporter {
    private let exporters: [any MetricExporter]

    public init(exporters: [any MetricExporter]) {
        self.exporters = exporters
    }

    public func export(_ metrics: [MetricSnapshot]) async throws {
        // Export to all backends in parallel with fail-fast error handling
        try await withThrowingTaskGroup(of: Void.self) { group in
            for exporter in exporters {
                group.addTask {
                    try await exporter.export(metrics)
                }
            }

            // Wait for all tasks, propagating first error
            try await group.waitForAll()
        }
    }

    public func flush() async throws {
        // Flush all exporters with fail-fast error handling
        try await withThrowingTaskGroup(of: Void.self) { group in
            for exporter in exporters {
                group.addTask {
                    try await exporter.flush()
                }
            }

            try await group.waitForAll()
        }
    }

    public func shutdown() async {
        // Shutdown doesn't throw, but we still want parallel execution
        await withTaskGroup(of: Void.self) { group in
            for exporter in exporters {
                group.addTask {
                    await exporter.shutdown()
                }
            }
        }
    }
}

// MARK: - Error Types

/// Errors that can occur in metric exporters.
public enum MetricExporterError: Error, Sendable {
    case bufferOverflow(current: Int, attempted: Int, max: Int)
}

// MARK: - Instrumentation

/// Statistics about exporter operation.
public struct ExporterStats: Sendable {
    public let exportsTotal: Int
    public let exportFailuresTotal: Int
    public let metricsExportedTotal: Int
    public let metricsDroppedTotal: Int
    public let currentBufferSize: Int
}

// MARK: - Null Exporter

/// A no-op exporter for testing or disabling metrics.
public struct NullExporter: MetricExporter {
    public init() {}

    public func export(_ metrics: [MetricSnapshot]) async throws {
        // Intentionally empty
    }
}
