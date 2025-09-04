import Foundation
import Logging

/// Simple cross-platform logging shim for PipelineKit.
/// Uses SwiftLog under the hood to allow OSLog backends on Apple and
/// stream/file backends on Linux.
enum PipelineKitLogger {
    static let core = Logger(label: "PipelineKit.Core")
    static func make(category: String) -> Logger { Logger(label: "PipelineKit.\(category)") }
}
