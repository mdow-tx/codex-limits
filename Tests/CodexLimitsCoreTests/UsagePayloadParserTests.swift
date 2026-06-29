import XCTest
@testable import CodexLimitsCore

final class UsagePayloadParserTests: XCTestCase {
    func testParsesGeneralAndSparkBuckets() throws {
        let payload = """
        {
          "rateLimitStatus": [
            {
              "limitName": null,
              "buckets": [
                {"windowDurationMins": 300, "usedPercent": 11, "resetsAt": "2026-05-08T20:00:00Z"},
                {"windowDurationMins": 10080, "usedPercent": 8, "resetsAt": "2026-05-12T00:00:00Z"}
              ]
            },
            {
              "limitName": "gpt-5.3-codex-spark",
              "buckets": [
                {"windowDurationMins": 300, "usedPercent": 0, "resetsAt": "2026-05-08T23:56:00Z"},
                {"windowDurationMins": 10080, "usedPercent": 0, "resetsAt": "2026-05-15T00:00:00Z"}
              ]
            }
          ],
          "creditDetails": {"balance": 0}
        }
        """
        let snapshot = try UsagePayloadParser.parse(
            data: Data(payload.utf8),
            sourceStatus: .liveStructured,
            sourceDescription: "test"
        )

        XCTAssertEqual(snapshot.buckets.count, 4)
        XCTAssertEqual(snapshot.buckets.first { $0.group == .general && $0.window == .fiveHour }?.remainingPercent, 89)
        XCTAssertEqual(snapshot.buckets.first { $0.group == .spark && $0.window == .weekly }?.remainingPercent, 100)
        XCTAssertEqual(snapshot.credit?.balance, 0)
    }

    func testParsesRemainingPercentDirectly() throws {
        let payload = """
        {"rate_limit_status":{"core":{"limit_name":"core","bucket":{"window_duration_mins":300,"remaining_percent":42,"reset_at":1770000000}}}}
        """
        let snapshot = try UsagePayloadParser.parse(
            data: Data(payload.utf8),
            sourceStatus: .cachedStructured,
            sourceDescription: "test"
        )

        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(snapshot.buckets[0].remainingPercent, 42)
        XCTAssertEqual(snapshot.buckets[0].window, .fiveHour)
    }

    func testParsesCodexRateLimitsEventPayload() throws {
        let payload = """
        {
          "type": "codex.rate_limits",
          "metered_limit_name": "codex",
          "rate_limits": {
            "primary": {"used_percent": 12.5, "window_minutes": 300, "reset_at": 1770000000},
            "secondary": {"used_percent": 40, "window_minutes": 10080, "reset_at": 1770500000}
          },
          "credits": {"has_credits": true, "unlimited": false, "balance": "9"}
        }
        """
        let snapshot = try UsagePayloadParser.parse(
            data: Data(payload.utf8),
            sourceStatus: .cachedStructured,
            sourceDescription: "event"
        )

        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first { $0.window == .fiveHour }?.remainingPercent, 87.5)
        XCTAssertEqual(snapshot.buckets.first { $0.window == .weekly }?.windowDurationMins, 10080)
        XCTAssertEqual(snapshot.credit?.balance, 9)
        XCTAssertEqual(snapshot.credit?.available, true)
    }

    func testParsesArbitraryAdditionalRateLimitAndMetadata() throws {
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {"used_percent": 5, "limit_window_seconds": 18000, "reset_at": 1770000000}
          },
          "additional_rate_limits": [
            {
              "metered_feature": "codex_bengalfox",
              "limit_name": "gpt-5.2-codex-sonic",
              "rate_limit": {
                "primary_window": {"used_percent": 70, "limit_window_seconds": 18000, "reset_at": 1770000000}
              }
            }
          ],
          "spend_control": {
            "individual_limit": {
              "limit": "25000",
              "used": "8000",
              "remaining_percent": 68,
              "reset_at": 1770500000
            }
          },
          "rate_limit_reached_type": {"type": "workspace_member_credits_depleted"}
        }
        """
        let snapshot = try UsagePayloadParser.parse(
            data: Data(payload.utf8),
            sourceStatus: .liveStructured,
            sourceDescription: "backend"
        )

        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first { $0.group == .general }?.remainingPercent, 95)
        let custom = try XCTUnwrap(snapshot.buckets.first { $0.group.rawValue == "codex_bengalfox" })
        XCTAssertEqual(custom.group.displayName, "Codex Bengalfox")
        XCTAssertEqual(custom.remainingPercent, 30)
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.rateLimitReachedType, "workspace_member_credits_depleted")
        XCTAssertEqual(snapshot.spendControl?.remainingPercent, 68)
    }

    func testMalformedPayloadFails() {
        XCTAssertThrowsError(try UsagePayloadParser.parse(
            data: Data(#"{"hello":"world"}"#.utf8),
            sourceStatus: .cachedStructured,
            sourceDescription: "test"
        ))
    }

    func testAccessibilityTextParser() throws {
        let snapshot = try XCTUnwrap(AccessibilityTextParser.parse(text: """
        Rate limits remaining
        5h
        89% 3:00 PM
        Weekly
        92% May 12
        """))

        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets[0].remainingPercent, 89)
        XCTAssertEqual(snapshot.buckets[1].window, .weekly)
    }
}
