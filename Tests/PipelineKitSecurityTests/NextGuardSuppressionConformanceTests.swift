//
//  NextGuardSuppressionConformanceTests.swift
//  PipelineKit
//
//  Pins the #97 re-arm for security middleware: these types short-circuit
//  only by throwing, which the chain builder detects since 0.6.
//

import XCTest
import PipelineKitCore
import PipelineKitSecurity

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testThrowBasedSecurityMiddlewaresDoNotSuppressNextGuardWarnings() {
        XCTAssertFalse(ValidationMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(SecurityPolicyMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(AuthenticationMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(AuthorizationMiddleware.self is any NextGuardWarningSuppressing.Type)
    }
}
