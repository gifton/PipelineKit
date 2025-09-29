import XCTest
import PipelineKitPooling

// Registers a global test observer to perform cleanup after the entire test
// bundle finishes. This ensures background maintenance tasks (like the
// PoolRegistry cleanup loop) are cancelled so the process can exit cleanly.
final class GlobalTestTeardownObserver: NSObject, XCTestObservation {
    func testBundleDidFinish(_ testBundle: Bundle) {
        // Call the static shutdown method to cleanly stop background tasks
        PoolRegistry.shutdown()
    }
}

// Register at module load time.
private let _registerGlobalTestTeardownObserver: Void = {
    XCTestObservationCenter.shared.addTestObserver(GlobalTestTeardownObserver())
}()