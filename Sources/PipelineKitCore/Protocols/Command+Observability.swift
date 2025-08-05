import Foundation

// MARK: - Observability Hooks

public extension Command {
    /// Called when the command execution starts.
    ///
    /// Default implementation does nothing.
    /// Override to setup custom observability context.
    ///
    /// - Parameter context: The command execution context
    func setupObservability(context: CommandContext) async {
        // Default: no observability setup
    }
    
    /// Called when the command execution completes successfully.
    ///
    /// Default implementation does nothing.
    /// Override to record success metrics or events.
    ///
    /// - Parameters:
    ///   - context: The command execution context
    ///   - result: The execution result
    func observabilityDidComplete(context: CommandContext, result: Result) async {
        // Default: no completion tracking
    }
    
    /// Called when the command execution fails.
    ///
    /// Default implementation does nothing.
    /// Override to record failure metrics or events.
    ///
    /// - Parameters:
    ///   - context: The command execution context
    ///   - error: The error that occurred
    func observabilityDidFail(context: CommandContext, error: Error) async {
        // Default: no failure tracking
    }
}

// MARK: - Metrics Collection

public extension Command {
    /// Called before command execution for metrics collection.
    ///
    /// Default implementation does nothing.
    /// Override to collect pre-execution metrics.
    ///
    /// - Parameter metrics: Any metrics collector instance
    func willExecute(metrics: Any) {
        // Default: no metrics collection
    }
    
    /// Called after command execution for metrics collection.
    ///
    /// Default implementation does nothing.
    /// Override to collect post-execution metrics.
    ///
    /// - Parameters:
    ///   - metrics: Any metrics collector instance
    ///   - result: The execution result
    func didExecute(metrics: Any, result: Result) {
        // Default: no metrics collection
    }
    
    /// Called when command execution fails for metrics collection.
    ///
    /// Default implementation does nothing.
    /// Override to collect failure metrics.
    ///
    /// - Parameters:
    ///   - metrics: Any metrics collector instance
    ///   - error: The error that occurred
    func didFail(metrics: Any, error: Error) {
        // Default: no metrics collection
    }
}

// MARK: - Observability Metadata

public extension Command {
    /// Custom properties to include in observability events.
    ///
    /// Default implementation returns empty dictionary.
    /// Override to provide command-specific properties.
    var observabilityProperties: [String: Any] {
        return [:]
    }
    
    /// Custom tags for metrics and tracing.
    ///
    /// Default implementation returns empty dictionary.
    /// Override to provide command-specific tags.
    var observabilityTags: [String: String] {
        return [:]
    }
    
    /// The operation name for tracing.
    ///
    /// Default implementation returns the command type name.
    /// Override to provide a custom operation name.
    var operationName: String {
        return String(describing: type(of: self))
    }
}
