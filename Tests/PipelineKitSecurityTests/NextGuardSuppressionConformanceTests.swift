import XCTest
import PipelineKitCore
import PipelineKitSecurity

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testShortCircuitingSecurityMiddlewaresSuppressNextGuardWarnings() {
        XCTAssertTrue(ValidationMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(SecurityPolicyMiddleware.self is any NextGuardWarningSuppressing.Type)
    }
}
