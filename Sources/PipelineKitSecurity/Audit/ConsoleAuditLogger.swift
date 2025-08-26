import Foundation
#if canImport(os)
import os
#endif

/// A simple audit logger that outputs events to the console.
///
/// This logger formats events in a human-readable format suitable for
/// development and debugging. It's a struct (not an actor) for minimal
/// overhead since console output is inherently synchronous.
///
/// Example output:
/// ```
/// [2024-01-19 10:30:45] AUDIT [command.started] commandType=CreateUser commandId=abc123 userId=user456
/// ```
public struct ConsoleAuditLogger: AuditLogger {
    /// The date formatter for timestamps
    private let dateFormatter: DateFormatter
    
    /// Whether to include all metadata or just key fields
    public let verbose: Bool
    
    /// Whether to use print() or Swift's logger
    public let useStandardOutput: Bool
    
    /// Creates a new console audit logger.
    ///
    /// - Parameters:
    ///   - verbose: If true, includes all metadata. If false, only key fields.
    ///   - useStandardOutput: If true, uses print(). If false, uses os_log.
    public init(verbose: Bool = false, useStandardOutput: Bool = true) {
        self.verbose = verbose
        self.useStandardOutput = useStandardOutput
        
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.dateFormatter.timeZone = TimeZone.current
    }
    
    // MARK: - AuditLogger Conformance
    
    public func log(_ event: any AuditEvent) async {
        let output = formatEvent(event)
        
        if useStandardOutput {
            print(output)
        } else {
            #if canImport(os)
            os_log(.info, "%{public}@", output)
            #else
            print(output)
            #endif
        }
    }
    
    // MARK: - Private Helpers
    
    private func formatEvent(_ event: any AuditEvent) -> String {
        let timestamp = dateFormatter.string(from: event.timestamp)
        let eventType = event.eventType
        
        var output = "[\(timestamp)] AUDIT [\(eventType)]"
        
        // Add metadata
        let metadata = formatMetadata(event.metadata)
        if !metadata.isEmpty {
            output += " \(metadata)"
        }
        
        return output
    }
    
    private func formatMetadata(_ metadata: [String: any Sendable]) -> String {
        let keys: [String]
        
        if verbose {
            // Include all metadata
            keys = metadata.keys.sorted()
        } else {
            // Only include important keys
            let importantKeys = [
                "commandType", "commandId", "userId", "sessionId",
                "resource", "principal", "error", "duration",
                "traceId", "spanId"
            ]
            keys = metadata.keys.filter { importantKeys.contains($0) }.sorted()
        }
        
        let pairs = keys.compactMap { key -> String? in
            guard let value = metadata[key] else { return nil }
            return "\(key)=\(formatValue(value))"
        }
        
        return pairs.joined(separator: " ")
    }
    
    private func formatValue(_ value: any Sendable) -> String {
        switch value {
        case let string as String:
            // Quote strings with spaces
            return string.contains(" ") ? "\"\(string)\"" : string
            
        case let number as NSNumber:
            // Format numbers nicely
            if let duration = number as? TimeInterval {
                return String(format: "%.3fs", duration)
            }
            return "\(number)"
            
        case let date as Date:
            return dateFormatter.string(from: date)
            
        case let bool as Bool:
            return bool ? "true" : "false"
            
        case let uuid as UUID:
            return uuid.uuidString
            
        case let array as [Any]:
            return "[\(array.count) items]"
            
        case let dict as [String: Any]:
            return "{\(dict.count) fields}"
            
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Convenience Initializers

public extension ConsoleAuditLogger {
    /// Creates a production console logger with default settings.
    static var production: ConsoleAuditLogger {
        ConsoleAuditLogger(verbose: false, useStandardOutput: false)
    }
    
    /// Creates a development console logger with verbose output.
    static var development: ConsoleAuditLogger {
        ConsoleAuditLogger(verbose: true, useStandardOutput: true)
    }
}
