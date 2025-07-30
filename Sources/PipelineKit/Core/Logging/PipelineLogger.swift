//
//  PipelineLogger.swift
//  PipelineKit
//
//  Created by Assistant on 7/30/25.
//  Copyright © 2025 All rights reserved.
//

import Foundation
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

/// Fallback logging for older OS versions
@available(macOS, deprecated: 11.0, message: "Use PipelineLogger for better structured logging")
@available(iOS, deprecated: 14.0, message: "Use PipelineLogger for better structured logging")
public struct LegacyLogger {
    /// Logs a message to stdout with timestamp
    public static func log(_ message: String, category: String = "PipelineKit") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(category)] \(message)")
    }
}