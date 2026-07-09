import XCTest
@testable import CodexLimitsCore

final class CodexAuthCompatibilityTests: XCTestCase {
    func testDecodesAuthWithoutLegacyModeLabel() throws {
        let data = Data("""
        {
          "tokens": {
            "access_token": "token-for-test-only",
            "account_id": "account-for-test-only"
          }
        }
        """.utf8)

        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)

        XCTAssertNil(auth.authMode)
        XCTAssertEqual(auth.tokens?.accessToken, "token-for-test-only")
        XCTAssertEqual(auth.tokens?.accountID, "account-for-test-only")
    }
}
