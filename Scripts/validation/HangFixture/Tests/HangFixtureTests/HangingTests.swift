import Darwin
import Foundation
import XCTest

/// Test-only process fixture. V04's Python harness acknowledges ownership before
/// releasing this test into its hang, and independently cleans its exact PID.
final class HangingTests: XCTestCase {
    func testNormalCompletion() {
        print("V04_XCTEST_NORMAL_COMPLETION")
    }

    func testAcknowledgedHang() throws {
        let path: String = try XCTUnwrap(ProcessInfo.processInfo.environment["V04_FIXTURE_DIR"])
        let directory: URL = URL(fileURLWithPath: path, isDirectory: true)
        let registration: Data = try JSONSerialization.data(withJSONObject: ["pid": getpid()])
        try registration.write(to: directory.appendingPathComponent("xctest-pid.json"), options: .atomic)

        // Independent last-resort bound if both watchdog and harness disappear.
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { _exit(90) }
        let grant: URL = directory.appendingPathComponent("hang")
        let deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: grant.path) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Ownership acknowledgement was not granted")
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try Data("V04_XCTEST_HANG_ACKNOWLEDGED\n".utf8).write(
            to: directory.appendingPathComponent("hang-acknowledged"), options: .atomic)
        print("V04_XCTEST_HANG_ACKNOWLEDGED pid=\(getpid())")
        fflush(stdout)
        DispatchSemaphore(value: 0).wait()
    }
}
