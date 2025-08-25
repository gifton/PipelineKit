import Foundation
import PipelineKitCore
import Atomics

/// A token representing an acquired semaphore resource that automatically releases on cleanup.
///
/// `SemaphoreToken` provides safe, automatic resource management for semaphore acquisitions.
/// The token releases its resource when deinitialized, preventing resource leaks even if
/// tasks are cancelled or errors occur.
///
/// ## Design
///
/// This token uses a closure-based approach that allows different semaphore implementations
/// to provide their own release logic while maintaining a unified token type in Core:
/// - **Automatic Cleanup**: Resources are released even if tasks are cancelled
/// - **Prevents Double-Release**: The token tracks its release state atomically
/// - **Implementation Agnostic**: Works with any semaphore via the release handler
/// - **Memory Safe**: No retain cycles when using weak captures
///
/// ## Example
/// ```swift
/// let token = await semaphore.acquire()
/// // Use the resource...
/// token.release() // Explicit release
/// // Or let it auto-release when token goes out of scope
/// ```
public final class SemaphoreToken: @unchecked Sendable {
    /// The closure to call when releasing the resource.
    private let releaseHandler: @Sendable () -> Void
    
    /// Atomic flag tracking release state to prevent double-release.
    private let released = ManagedAtomic<Bool>(false)
    
    /// Timestamp when this token was acquired.
    private let acquiredAt: Date
    
    /// Creates a new semaphore token with a custom release handler.
    ///
    /// - Parameter releaseHandler: The closure to call when releasing the resource.
    ///                            This should typically capture the semaphore weakly
    ///                            to avoid retain cycles.
    public init(releaseHandler: @Sendable @escaping () -> Void) {
        self.releaseHandler = releaseHandler
        self.acquiredAt = Date()
    }
    
    /// Whether this token has been released.
    public var isReleased: Bool {
        released.load(ordering: .relaxed)
    }
    
    /// How long this token has held the resource.
    public var holdDuration: TimeInterval {
        Date().timeIntervalSince(acquiredAt)
    }
    
    /// Explicitly releases the semaphore resource.
    ///
    /// This method is idempotent - calling it multiple times is safe.
    /// The resource is also automatically released when the token is deinitialized.
    public func release() {
        // Atomic exchange ensures we only release once
        if released.exchange(true, ordering: .acquiring) == false {
            releaseHandler()
        }
    }
    
    /// Ensures the resource is released when the token is deallocated.
    deinit {
        release() // Auto-release if not explicitly released
    }
}

// MARK: - Diagnostic Support

extension SemaphoreToken: CustomStringConvertible {
    public var description: String {
        "SemaphoreToken(held: \(String(format: "%.2f", holdDuration))s, released: \(isReleased))"
    }
}
