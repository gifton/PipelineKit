import Foundation

/// A token representing an acquired semaphore resource that automatically releases on cleanup.
///
/// `SemaphoreToken` provides safe, automatic resource management for semaphore acquisitions.
/// The token releases its resource when deinitialized, preventing resource leaks even if
/// tasks are cancelled or errors occur.
///
/// ## Design
///
/// This token-based approach solves several critical issues:
/// - **Automatic Cleanup**: Resources are released even if tasks are cancelled
/// - **Prevents Double-Release**: The token tracks its release state
/// - **Task Cancellation Safe**: Works correctly with Swift's cooperative cancellation
/// - **Memory Safe**: No retain cycles or leaked continuations
///
/// ## Example
/// ```swift
/// let token = try await semaphore.acquire()
/// // Use the resource...
/// // Token automatically releases when it goes out of scope
/// ```
public final class SemaphoreToken: Sendable {
    private let semaphore: BackPressureAsyncSemaphore
    internal let id: UUID
    private let acquiredAt: Date
    private let releaseState = ReleaseState()
    
    /// Whether this token has been released.
    public var isReleased: Bool {
        get async {
            await releaseState.isReleased
        }
    }
    
    /// How long this token has held the resource.
    public var holdDuration: TimeInterval {
        Date().timeIntervalSince(acquiredAt)
    }
    
    /// Creates a new semaphore token.
    ///
    /// - Parameters:
    ///   - semaphore: The semaphore that created this token
    ///   - id: Unique identifier for this acquisition
    internal init(semaphore: BackPressureAsyncSemaphore, id: UUID = UUID()) {
        self.semaphore = semaphore
        self.id = id
        self.acquiredAt = Date()
    }
    
    /// Explicitly releases the semaphore resource.
    ///
    /// This method is idempotent - calling it multiple times is safe.
    /// The resource is also automatically released when the token is deinitialized.
    public func release() async {
        let wasReleased = await releaseState.setReleased()
        guard !wasReleased else { return }
        
        await semaphore.releaseToken(self)
    }
    
    /// Ensures the resource is released when the token is deallocated.
    deinit {
        // We can't await in deinit, so we need to handle this carefully
        // This is the safety net for unexpected cleanup scenarios
        Task { [semaphore, id, releaseState] in
            let wasReleased = await releaseState.isReleased
            if !wasReleased {
                await semaphore.emergencyRelease(tokenId: id)
            }
        }
    }
}

// MARK: - Equatable & Hashable

extension SemaphoreToken: Equatable {
    public static func == (lhs: SemaphoreToken, rhs: SemaphoreToken) -> Bool {
        lhs.id == rhs.id
    }
}

extension SemaphoreToken: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Diagnostic Support

extension SemaphoreToken: CustomStringConvertible {
    public var description: String {
        "SemaphoreToken(id: \(id), held: \(String(format: "%.2f", holdDuration))s)"
    }
}

// MARK: - Release State Actor

/// Actor to manage release state without atomics
private actor ReleaseState {
    private var released = false
    
    var isReleased: Bool {
        released
    }
    
    /// Sets the released state and returns the previous value
    func setReleased() -> Bool {
        let wasReleased = released
        released = true
        return wasReleased
    }
}

