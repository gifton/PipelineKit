import Foundation
import Synchronization

struct WarningConfigurationSnapshot: Sendable {
    let emitWarnings: Bool
    let warningHandler: (@Sendable (String) -> Void)?
}

enum NextGuardWarningScope {
    @TaskLocal static var isSuppressed = false
}

/// Configuration for NextGuard warning behavior
public final class NextGuardConfiguration: Sendable {
    /// Global configuration for NextGuard warnings
    public static let shared = NextGuardConfiguration()
    
    private let configuration = Mutex(WarningConfigurationSnapshot(emitWarnings: true, warningHandler: nil))

    /// Whether to emit warnings when middleware doesn't call next()
    public var emitWarnings: Bool {
        get { snapshot().emitWarnings }
        set {
            update { WarningConfigurationSnapshot(emitWarnings: newValue, warningHandler: $0.warningHandler) }
        }
    }
    
    /// Custom warning handler - allows users to integrate with their logging system
    public var warningHandler: (@Sendable (String) -> Void)? {
        get { snapshot().warningHandler }
        set {
            update { WarningConfigurationSnapshot(emitWarnings: $0.emitWarnings, warningHandler: newValue) }
        }
    }
    
    private init() {}

    func snapshot() -> WarningConfigurationSnapshot {
        configuration.withLock { $0 }
    }

    func configure(emitWarnings: Bool, warningHandler: (@Sendable (String) -> Void)?) {
        update { _ in WarningConfigurationSnapshot(emitWarnings: emitWarnings, warningHandler: warningHandler) }
    }

    private func update(_ transform: (WarningConfigurationSnapshot) -> WarningConfigurationSnapshot) {
        let previous = configuration.withLock { current in
            let previous = current
            current = transform(previous)
            return previous
        }
        // A replaced callback may own objects whose deinit reenters configuration.
        // Keep it alive past unlock; testReplacingCallbackCanReenterConfiguration
        // covers all public callback-replacement paths.
        withExtendedLifetime(previous) {}
    }
    
    /// Convenience method to disable all warnings
    public static func disableWarnings() {
        shared.emitWarnings = false
    }
    
    /// Convenience method to enable warnings with custom handler
    public static func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void) {
        shared.configure(emitWarnings: true, warningHandler: handler)
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
