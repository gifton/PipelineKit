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
}
