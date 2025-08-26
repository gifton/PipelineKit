import Foundation

/// A minimal protocol for types that can record metrics.
///
/// This protocol provides the single point of abstraction for metrics recording,
/// enabling testability without introducing heavy abstractions.
public protocol MetricRecorder: Sendable {
    /// Records a metric snapshot.
    func record(_ snapshot: MetricSnapshot) async
}
