import XCTest
@testable import CodexLimitsCore

final class SnapshotFormattingTests: XCTestCase {
    func testLowestRemainingBucketWinsMenuTitle() {
        let snapshot = RateLimitSnapshot(
            buckets: [
                RateLimitBucket(group: .general, window: .weekly, label: "Weekly", remainingPercent: 92, usedPercent: 8, resetAt: nil, resetLabel: "May 12", windowDurationMins: 10080),
                RateLimitBucket(group: .general, window: .fiveHour, label: "5h", remainingPercent: 89, usedPercent: 11, resetAt: nil, resetLabel: "3:00 PM", windowDurationMins: 300)
            ],
            credit: nil,
            lastUpdated: Date(),
            sourceStatus: .liveStructured,
            sourceDescription: "test"
        )

        XCTAssertEqual(SnapshotFormatting.menuTitle(for: snapshot), "89%")
    }

    func testUnknownMenuTitleWhenNoBuckets() {
        let snapshot = RateLimitSnapshot(
            buckets: [],
            credit: nil,
            lastUpdated: Date(),
            sourceStatus: .unavailable,
            sourceDescription: "test"
        )

        XCTAssertEqual(SnapshotFormatting.menuTitle(for: snapshot), "Codex ?")
    }
}
