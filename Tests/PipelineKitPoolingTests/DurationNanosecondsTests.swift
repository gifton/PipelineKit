import XCTest
@testable import PipelineKitPooling

final class DurationNanosecondsTests: XCTestCase {
    func testDurationNanosecondsIncludesWholeSeconds() {
        let cases: [(Duration, UInt64)] = [
            (.milliseconds(250), 250_000_000),
            (.seconds(1), 1_000_000_000),
            (.milliseconds(1250), 1_250_000_000),
            (Duration(secondsComponent: 1, attosecondsComponent: -250_000_000_000_000_000), 750_000_000),
            (Duration(secondsComponent: 0, attosecondsComponent: 1_999_999_999), 1)
        ]
        for (duration, expected) in cases {
            XCTAssertEqual(durationNanosecondsClamped(duration), expected)
        }
    }

    func testDurationNanosecondsClampsBoundaries() {
        let cases: [(Duration, UInt64)] = [
            (.zero, 0),
            (.milliseconds(-1), 0),
            (Duration(secondsComponent: 18_446_744_073, attosecondsComponent: 709_551_614_999_999_999), UInt64.max - 1),
            (Duration(secondsComponent: 18_446_744_073, attosecondsComponent: 709_551_615_999_999_999), UInt64.max),
            (Duration(secondsComponent: 18_446_744_073, attosecondsComponent: 709_551_616_000_000_000), UInt64.max),
            (.seconds(18_446_744_074), UInt64.max)
        ]
        for (duration, expected) in cases {
            XCTAssertEqual(durationNanosecondsClamped(duration), expected)
        }
    }
}
