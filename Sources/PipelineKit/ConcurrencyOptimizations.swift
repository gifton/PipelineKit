// Re-export all concurrency optimization components for convenient import

// Batching
@_exported import struct PipelineKit.BatchProcessor
@_exported import protocol PipelineKit.BatchAwareMiddleware
@_exported import struct PipelineKit.BatchMiddlewareAdapter
@_exported import struct PipelineKit.BatchContext
@_exported import struct PipelineKit.BatchContextKey

// Parallel Execution
@_exported import struct PipelineKit.ParallelMiddlewareExecutor
@_exported import actor PipelineKit.ParallelPipeline
@_exported import class PipelineKit.WorkStealingQueue
@_exported import actor PipelineKit.WorkStealingPipelineExecutor

// Optimized Components
@_exported import struct PipelineKit.OptimizedConcurrentPipeline
@_exported import class PipelineKit.OptimizedCommandContext

// Adaptive Concurrency
@_exported import actor PipelineKit.AdaptiveConcurrencyController
@_exported import actor PipelineKit.AdaptivePipeline
@_exported import struct PipelineKit.AdaptiveMetrics

// Lock-Free Components
@_exported import class PipelineKit.LockFreeQueue
@_exported import class PipelineKit.LockFreeMetricsCollector
@_exported import actor PipelineKit.LockFreePipeline