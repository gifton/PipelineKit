/// Converts a duration to whole nanoseconds, clamping to the UInt64 range.
func durationNanosecondsClamped(_ duration: Duration) -> UInt64 {
    guard duration > .zero else { return 0 }
    let maximum = Duration(secondsComponent: 18_446_744_073, attosecondsComponent: 709_551_615_000_000_000)
    guard duration < maximum else { return .max }
    let components = duration.components
    let (whole, multiplyOverflow) = UInt64(components.seconds)
        .multipliedReportingOverflow(by: 1_000_000_000)
    guard !multiplyOverflow else { return .max }
    let fraction = UInt64(components.attoseconds / 1_000_000_000)
    let (result, addOverflow) = whole.addingReportingOverflow(fraction)
    return addOverflow ? .max : result
}
