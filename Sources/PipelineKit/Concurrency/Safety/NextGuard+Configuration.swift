import Foundation

// MARK: - Public Configuration API

public extension NextGuard {
    /// Configures NextGuard warning behavior
    enum WarningMode {
        /// Emit all warnings (default)
        case all
        
        /// Disable all warnings
        case disabled
        
        /// Custom configuration
        case custom(emitWarnings: Bool)
    }
    
    /// Sets the warning mode for NextGuard
    /// - Parameter mode: The warning mode to use
    static func setWarningMode(_ mode: WarningMode) {
        switch mode {
        case .all:
            NextGuardConfiguration.shared.emitWarnings = true
            
        case .disabled:
            NextGuardConfiguration.shared.emitWarnings = false
            
        case .custom(let emit):
            NextGuardConfiguration.shared.emitWarnings = emit
        }
    }
    
    /// Sets a custom warning handler
    /// - Parameter handler: A closure that receives warning messages
    /// - Note: Setting a custom handler automatically enables warnings
    static func setWarningHandler(_ handler: @escaping @Sendable (String) -> Void) {
        NextGuardConfiguration.shared.warningHandler = handler
        NextGuardConfiguration.shared.emitWarnings = true
    }
    
    /// Disables all NextGuard warnings
    static func disableWarnings() {
        setWarningMode(.disabled)
    }
    
    /// Resets to default configuration
    static func resetConfiguration() {
        NextGuardConfiguration.shared.emitWarnings = true
        NextGuardConfiguration.shared.warningHandler = nil
    }
}

// MARK: - Convenience for Testing

public extension NextGuard {
    /// Temporarily disables warnings for the duration of the provided closure
    /// - Parameter operation: The operation to run without warnings
    /// - Returns: The result of the operation
    static func withoutWarnings<Result>(_ operation: () throws -> Result) rethrows -> Result {
        let previousState = NextGuardConfiguration.shared.emitWarnings
        NextGuardConfiguration.shared.emitWarnings = false
        defer { NextGuardConfiguration.shared.emitWarnings = previousState }
        return try operation()
    }
    
    /// Temporarily disables warnings for the duration of the provided async closure
    /// - Parameter operation: The async operation to run without warnings
    /// - Returns: The result of the operation
    static func withoutWarnings<Result>(_ operation: () async throws -> Result) async rethrows -> Result {
        let previousState = NextGuardConfiguration.shared.emitWarnings
        NextGuardConfiguration.shared.emitWarnings = false
        defer { NextGuardConfiguration.shared.emitWarnings = previousState }
        return try await operation()
    }
}
