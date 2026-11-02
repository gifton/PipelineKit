import Foundation
import XCTest
@testable import PipelineKitSecurity

final class AuditLoggerCapacityTests: XCTestCase {
    func testZeroCapacityCountsDropsWithoutRetainingEvents() async {
        let logger = InMemoryAuditLogger(maxEvents: 0)
        for i in 0..<10 { await logger.log(GenericAuditEvent(eventType: "event.\(i)")) }
        let count = await logger.count
        let drops = await logger.droppedEventsCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(drops, 10)
        var iterator = logger.health.makeAsyncIterator()
        guard case let .dropped(count, reason) = await iterator.next() else {
            return XCTFail("Expected drop notification")
        }
        XCTAssertEqual(count, 10)
        XCTAssertEqual(reason, "Memory limit reached (0 events)")
    }

    func testOneCapacityEvictsOldest() async {
        let logger = InMemoryAuditLogger(maxEvents: 1)
        for i in 0..<11 { await logger.log(GenericAuditEvent(eventType: "event.\(i)")) }
        let events = await logger.allEvents()
        let drops = await logger.droppedEventsCount
        XCTAssertEqual(events.map(\.eventType), ["event.10"])
        XCTAssertEqual(drops, 10)
        var iterator = logger.health.makeAsyncIterator()
        guard case let .dropped(count, reason) = await iterator.next() else {
            return XCTFail("Expected drop notification")
        }
        XCTAssertEqual(count, 10)
        XCTAssertEqual(reason, "Memory limit reached (1 events)")
    }

    func testNilCapacityRetainsAll() async {
        let logger = InMemoryAuditLogger(maxEvents: nil)
        for i in 0..<11 { await logger.log(GenericAuditEvent(eventType: "event.\(i)")) }
        let events = await logger.allEvents()
        let drops = await logger.droppedEventsCount
        XCTAssertEqual(events.map(\.eventType), (0..<11).map { "event.\($0)" })
        XCTAssertEqual(drops, 0)
    }

    func testNegativeCapacityPreconditionProbe() {
        guard ProcessInfo.processInfo.environment["S06_NEGATIVE_PROBE"] == "1" else { return }
        print("S06_NEGATIVE_CAPACITY_REACHED")
        fflush(stdout)
        _ = InMemoryAuditLogger(maxEvents: -1)
    }
}
