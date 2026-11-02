//
//  PartitionedBulkheadConfigurationTests.swift
//  PipelineKit
//
//  reservedCapacityPercentage is the truthful name for the value historically
//  exposed as maxBorrowPercentage (which was always the lender's RESERVED
//  share, not a borrowing cap). The old name and init survive as deprecated
//  forwarding shims until 0.6.
//

import XCTest
@testable import PipelineKitCore
import PipelineKitResilience

final class PartitionedBulkheadConfigurationTests: XCTestCase {
    private static let partitions = [
        "default": PartitionedBulkheadMiddleware.PartitionConfig(capacity: 10)
    ]

    func testReservedCapacityPercentageIsPrimaryAndDefaultsUnchanged() {
        let config = PartitionedBulkheadMiddleware.Configuration(
            partitions: Self.partitions,
            partitionExtractor: { _, _ in "default" }
        )
        XCTAssertEqual(config.reservedCapacityPercentage, 0.2, accuracy: .ulpOfOne)
    }

    func testDeprecatedAliasAndInitForwardToReservedCapacityPercentage() {
        let config = PartitionedBulkheadMiddleware.Configuration(
            partitions: Self.partitions,
            partitionExtractor: { _, _ in "default" },
            reservedCapacityPercentage: 0.5
        )
        // Deprecation warnings below are expected: the test pins the shims.
        XCTAssertEqual(config.maxBorrowPercentage, 0.5, accuracy: .ulpOfOne)

        let legacy = PartitionedBulkheadMiddleware.Configuration(
            partitions: Self.partitions,
            partitionExtractor: { _, _ in "default" },
            maxBorrowPercentage: 0.3
        )
        XCTAssertEqual(legacy.reservedCapacityPercentage, 0.3, accuracy: .ulpOfOne)
    }

    func testReserveRoundingAndIntegerCapacityBoundaries() async {
        let cases: [(capacity: Int, fraction: Double, attempts: Int, borrowed: Int)] = [
            (1, 0, 2, 1), (1, 0.2, 2, 1), (1, 1, 1, 0),
            (2, 0.5, 2, 1), (3, 0.5, 3, 2), (5, 0.5, 4, 3),
            (10, 0.3, 8, 7), (10, 1, 1, 0),
            (Int.max, 0, 2, 2), (Int.max, 1.0.nextDown, 2, 2),
            (Int.max, 1, 1, 0), (Int.max - 1, 1, 1, 0)
        ]
        for item in cases {
            let middleware = PartitionedBulkheadMiddleware(configuration: .init(
                partitions: ["local": .init(capacity: 1), "donor": .init(capacity: item.capacity)],
                partitionExtractor: { _, _ in "local" }, defaultPartition: "local",
                reservedCapacityPercentage: item.fraction
            ))
            let subject = BulkheadAdmissionSubject.partitioned(middleware, partition: "local")
            let ledger = BulkheadHandlerLedger()
            let holder = launchBulkhead(subject, id: "held", ledger: ledger)
            while !(await ledger.entered("held")) { await Task.yield() }
            var attempts: [Task<String, Never>] = []
            for index in 0..<item.attempts {
                let id = "borrow-\(index)"
                attempts.append(launchBulkhead(subject, id: id, ledger: ledger, fails: index % 2 == 1))
                while !(await ledger.entered(id)) {
                    if await ledger.finished(id) { break }
                    await Task.yield()
                }
            }
            let label = "capacity=\(item.capacity), reserve=\(item.fraction)"
            let donor = await middleware.admissionSnapshot(partition: "donor")
            XCTAssertEqual(donor.active, item.borrowed, label)
            XCTAssertEqual(donor.queued, 0, label)
            let entries = await ledger.entries
            XCTAssertEqual(entries.count, item.borrowed + 1, label)
            for index in 0..<item.attempts {
                await ledger.release("borrow-\(index)")
                let result = await attempts[index].value
                XCTAssertEqual(result, index < item.borrowed ? (index % 2 == 1 ? "handlerError" : "success") : "rejected", label)
            }
            let restored = await middleware.admissionSnapshot(partition: "donor")
            XCTAssertEqual(restored.active, 0, label)
            await ledger.release("held")
            let result = await holder.value
            XCTAssertEqual(result, "success", label)
            let local = await subject.snapshot()
            XCTAssertEqual(local.active, 0, label)
            XCTAssertEqual(local.queued, 0, label)
        }
    }

    func testSelectorFallbackAndMetadataArePreserved() async throws {
        for emitMetrics in [false, true] {
            let middleware = PartitionedBulkheadMiddleware(configuration: .init(
                partitions: ["default": .init(capacity: 1), "named": .init(capacity: 1)],
                partitionExtractor: { command, _ in (command as? AdmissionCommand)?.id ?? "missing" },
                emitMetrics: emitMetrics
            ))
            for key in ["named", "missing"] {
                let context = CommandContext()
                let result = try await middleware.execute(AdmissionCommand(id: key), context: context) { command, _ in command.id }
                XCTAssertEqual(result, key)
                let effectiveKey = key == "named" ? "named" : "default"
                XCTAssertEqual(context.getMetadata()["bulkheadPartition"] as? String, effectiveKey)
                XCTAssertEqual(context.getMetadata()["bulkhead.partition"] as? String, emitMetrics ? effectiveKey : nil)
                XCTAssertEqual(context.getMetadata()["bulkhead.wasBorrowed"] as? Bool, emitMetrics ? false : nil)
                XCTAssertEqual(context.getMetadata()["bulkhead.wasQueued"] as? Bool, emitMetrics ? false : nil)
                let snapshot = await middleware.admissionSnapshot(partition: effectiveKey)
                XCTAssertEqual(snapshot.active, 0)
                XCTAssertEqual(snapshot.queued, 0)
            }
        }
        let missingDefault = PartitionedBulkheadMiddleware(configuration: .init(
            partitions: [:], partitionExtractor: { _, _ in "missing" }
        ))
        let context = CommandContext()
        do {
            _ = try await missingDefault.execute(AdmissionCommand(id: "missing"), context: context) { _, _ in
                XCTFail("Unknown partition must not execute the handler")
                return "unexpected"
            }
            XCTFail("Expected unknown-partition rejection")
        } catch PipelineError.middlewareError(_, let message, _) {
            XCTAssertTrue(message.contains("Unknown partition"))
        }
        XCTAssertEqual(context.getMetadata()["bulkheadPartition"] as? String, "default")
    }

    // Isolated process cases require the named precondition, not an incidental
    // arithmetic trap. Normal suite runs use valid public construction.
    func testConfigurationValidationProbe() {
        let environment = ProcessInfo.processInfo.environment
        let capacity = Int(environment["PIPELINEKIT_R03_CAPACITY"] ?? "1")!
        let queue = Int(environment["PIPELINEKIT_R03_QUEUE"] ?? "0")!
        let reserve = Double(environment["PIPELINEKIT_R03_RESERVE"] ?? "0.2")!
        _ = PartitionedBulkheadMiddleware(configuration: .init(
            partitions: ["default": .init(capacity: capacity, queueSize: queue)],
            partitionExtractor: { _, _ in "default" }, reservedCapacityPercentage: reserve
        ))
        XCTAssertNil(environment["PIPELINEKIT_R03_INVALID_CONFIG"], "Expected explicit configuration validation")
    }
}
