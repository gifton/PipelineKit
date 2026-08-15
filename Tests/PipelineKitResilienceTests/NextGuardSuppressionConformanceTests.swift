//
//  NextGuardSuppressionConformanceTests.swift
//  PipelineKit
//
//  Middlewares that intentionally short-circuit (throw a rejection or return
//  without calling next) must conform to NextGuardWarningSuppressing so their
//  normal rejection paths don't emit false debug "deallocated without calling
//  next()" warnings. Metatype assertions pin the contract without needing to
//  construct configurations.
//

import XCTest
import PipelineKitCore
import PipelineKitResilience

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testShortCircuitingResilienceMiddlewaresSuppressNextGuardWarnings() {
        XCTAssertTrue(BackPressureMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(CircuitBreakerMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(RateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(EnhancedRateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(BulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(PartitionedBulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(HealthCheckMiddleware.self is any NextGuardWarningSuppressing.Type)
    }
}
