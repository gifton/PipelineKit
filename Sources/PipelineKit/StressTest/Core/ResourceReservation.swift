import Foundation
import Atomics

/// Represents a reservation for a resource that hasn't been confirmed yet.
///
/// The reservation pattern ensures atomic resource allocation by separating
/// the increment operation from the safety check, preventing TOCTOU races.
public struct ResourceReservation: Sendable {
    /// Unique identifier for this reservation
    public let id: UUID
    
    /// Type of resource being reserved
    public let resourceType: SafetyResourceType
    
    /// Timestamp when reservation was created
    public let createdAt: Date
    
    /// Whether this reservation has been confirmed or cancelled
    internal let isActive: ManagedAtomic<Bool>
    
    /// Reference to the monitor that created this reservation
    internal weak var monitor: DefaultSafetyMonitor?
    
    init(id: UUID, resourceType: SafetyResourceType, monitor: DefaultSafetyMonitor) {
        self.id = id
        self.resourceType = resourceType
        self.createdAt = Date()
        self.isActive = ManagedAtomic<Bool>(true)
        self.monitor = monitor
    }
}

/// Handle for automatic reservation cleanup if not explicitly confirmed/cancelled.
///
/// This ensures reservations don't leak if an error occurs between
/// reservation and confirmation.
final class ReservationHandle: Sendable {
    private let reservation: ResourceReservation
    private let cleanupTask: Task<Void, Never>?
    
    init(reservation: ResourceReservation, timeout: TimeInterval = 5.0) {
        self.reservation = reservation
        
        // Start timeout task
        let reservationId = reservation.id
        let resourceType = reservation.resourceType
        let isActive = reservation.isActive
        let weakMonitor = reservation.monitor
        
        self.cleanupTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            
            // If still active after timeout, cancel it
            if isActive.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent).exchanged {
                // Notify monitor about timeout
                if let monitor = weakMonitor {
                    // Create a minimal reservation for cancellation
                    let timeoutReservation = ResourceReservation(
                        id: reservationId,
                        resourceType: resourceType,
                        monitor: monitor
                    )
                    await monitor.handleReservationTimeout(timeoutReservation)
                }
            }
        }
    }
    
    deinit {
        cleanupTask?.cancel()
        
        // If reservation is still active on dealloc, cancel it
        if reservation.isActive.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent).exchanged {
            let monitor = reservation.monitor
            let reservationCopy = reservation
            
            Task.detached { @Sendable in
                await monitor?.cancelReservation(reservationCopy)
            }
        }
    }
    
    /// Access the underlying reservation
    var value: ResourceReservation { reservation }
}


