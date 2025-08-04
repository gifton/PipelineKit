//
//  PipelineLogger.swift
//  PipelineKit
//
//  Created by Assistant on 7/30/25.
//  Copyright © 2025 All rights reserved.
//

import Foundation

#if canImport(OSLog)
import OSLog

/// Shared logger instances for PipelineKit components
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public struct PipelineLogger {
    /// Logger for core pipeline operations
    public static let core = Logger(subsystem: "com.pipelinekit", category: "core")
    
    /// Logger for security operations
    public static let security = Logger(subsystem: "com.pipelinekit", category: "security")
    
    /// Logger for observability and metrics
    public static let observability = Logger(subsystem: "com.pipelinekit", category: "observability")
    
    /// Logger for command bus operations
    public static let bus = Logger(subsystem: "com.pipelinekit", category: "bus")
    
    /// Logger for memory management
    public static let memory = Logger(subsystem: "com.pipelinekit", category: "memory")
    
    /// Logger for debugging (only enabled in DEBUG builds)
    public static let debug = Logger(subsystem: "com.pipelinekit", category: "debug")
}
#else
// Fallback for Linux - no-op logger
public struct PipelineLogger {
    public struct NoOpLogger {
        public func error(_ message: String) {}
        public func warning(_ message: String) {}
        public func info(_ message: String) {}
        public func debug(_ message: String) {}
        public func notice(_ message: String) {}
        public func trace(_ message: String) {}
    }
    
    public static let core = NoOpLogger()
    public static let security = NoOpLogger()
    public static let observability = NoOpLogger()
    public static let bus = NoOpLogger()
    public static let memory = NoOpLogger()
    public static let debug = NoOpLogger()
}
#endif

