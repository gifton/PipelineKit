import Foundation

/// Shared delay conversion exercised by TestSupportDelayNumericBoundaryTests and
/// TestPipelineNumericBoundaryTests. Values below one nanosecond truncate to zero.
internal func testDelayNanoseconds(_ seconds: TimeInterval) throws -> UInt64 {
    let scaled = seconds * 1_000_000_000
    guard seconds.isFinite, seconds >= 0, scaled < Double(UInt64.max) else {
        throw TestPipelineError.invalidDelay(seconds)
    }
    return UInt64(scaled)
}
