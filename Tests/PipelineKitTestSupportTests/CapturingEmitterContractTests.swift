import XCTest
import PipelineKitCore
import PipelineKitTestSupport

final class CapturingEmitterContractTests: XCTestCase {
    func testExpectedPropertiesRequirePresentStringValues() async {
        let emitter = CapturingEmitter()
        await emitter.emit(PipelineEvent(
            name: "event", properties: ["status": "ready", "count": 3, "extra": "allowed"],
            correlationID: "first"
        ))

        let matching = await emitter.assertEventEmitted(named: "event", withProperties: ["status": "ready"])
        let absent = await emitter.assertEventEmitted(named: "event", withProperties: ["missing": "value"])
        let nonString = await emitter.assertEventEmitted(named: "event", withProperties: ["count": "3"])
        let wrongString = await emitter.assertEventEmitted(named: "event", withProperties: ["status": "wrong"])
        let extra = await emitter.assertEventEmitted(named: "event", withProperties: ["status": "ready", "extra": "allowed"])

        XCTAssertNotNil(matching)
        XCTAssertNil(absent)
        XCTAssertNil(nonString)
        XCTAssertNil(wrongString)
        XCTAssertNotNil(extra)
    }

    func testNilAndEmptyPropertiesMatchByName() async {
        let emitter = CapturingEmitter()
        await emitter.emit(PipelineEvent(name: "other", correlationID: "other"))
        await emitter.emit(PipelineEvent(name: "event", properties: ["status": "wrong"], correlationID: "first"))
        await emitter.emit(PipelineEvent(name: "event", properties: ["status": "ready"], correlationID: "second"))
        await emitter.emit(PipelineEvent(name: "event", properties: ["status": "ready"], correlationID: "third"))

        let nilProperties = await emitter.assertEventEmitted(named: "event", withProperties: nil)
        let emptyProperties = await emitter.assertEventEmitted(named: "event", withProperties: [:])
        let missingName = await emitter.assertEventEmitted(named: "missing", withProperties: [:])
        let matchingProperties = await emitter.assertEventEmitted(named: "event", withProperties: ["status": "ready"])

        XCTAssertEqual(nilProperties?.correlationID, "first")
        XCTAssertEqual(emptyProperties?.correlationID, "first")
        XCTAssertNil(missingName)
        XCTAssertEqual(matchingProperties?.correlationID, "second")
    }
}
