import Foundation

/// Configuration for NextGuard warning behavior
/// 
/// Note: This uses @unchecked Sendable because the configuration is meant to be
/// set once at startup and rarely changed. The properties are simple flags that
/// are safe to read/write from multiple threads.
public final class NextGuardConfiguration: @unchecked Sendable {
    /// Global configuration for NextGuard warnings
    public static let shared = NextGuardConfiguration()
    
    /// Whether to emit warnings when middleware doesn't call next()
    public var emitWarnings: Bool = true
    
    // Removed timeout-specific suppression; use per-middleware suppression instead
    
    /// Custom warning handler - allows users to integrate with their logging system
    public var warningHandler: (@Sendable (String) -> Void)?
    
    private init() {}
    
    /// Convenience method to disable all warnings
    public static func disableWarnings() {
        shared.emitWarnings = false
    }
    
    /// Convenience method to enable warnings with custom handler
    public static func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void) {
        shared.warningHandler = handler
        shared.emitWarnings = true
    }
}

// MARK: - Environment Variable Support

extension NextGuardConfiguration {
    /// Loads configuration from environment variables
    static func loadFromEnvironment() {
        // Check for environment variable to disable warnings
        if ProcessInfo.processInfo.environment["PIPELINEKIT_DISABLE_NEXTGUARD_WARNINGS"] != nil {
            shared.emitWarnings = false
        }
        
        // No special test behavior required beyond global emitWarnings
    }
}
