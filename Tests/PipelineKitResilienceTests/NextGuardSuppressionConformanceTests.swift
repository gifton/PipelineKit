//
//  NextGuardSuppressionConformanceTests.swift
//  PipelineKit
//
//  Pins the #97 re-arm: throw-based short-circuiting middleware must NOT
//  conform to NextGuardWarningSuppressing. The chain builder detects error
//  exits itself since 0.6, and conforming would disarm the debug diagnostic
//  that catches a genuinely dropped chain (a silent return without next()).
//

import XCTest
import PipelineKitCore
import PipelineKitResilience

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testThrowBasedResilienceMiddlewaresDoNotSuppressNextGuardWarnings() {
        XCTAssertFalse(BackPressureMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(CircuitBreakerMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(RateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(EnhancedRateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(BulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(PartitionedBulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(HealthCheckMiddleware.self is any NextGuardWarningSuppressing.Type)
    }
}
