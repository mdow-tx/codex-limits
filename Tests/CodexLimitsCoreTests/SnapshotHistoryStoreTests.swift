import CodexLimitsCore
import XCTest

final class SnapshotHistoryStoreTests: XCTestCase {
    func testAppendsAndTrimsHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("history.json")
        let store = SnapshotHistoryStore(fileURL: file, maxEntries: 2)

        try store.append(snapshot(minutesAgo: 10, remaining: 90))
        try store.append(snapshot(minutesAgo: 5, remaining: 80))
        try store.append(snapshot(minutesAgo: 0, remaining: 70))

        let history = try store.load()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].buckets[0].remainingPercent, 80)
        XCTAssertEqual(history[1].buckets[0].remainingPercent, 70)
    }

    private func snapshot(minutesAgo: TimeInterval, remaining: Double) -> RateLimitSnapshot {
        RateLimitSnapshot(
            buckets: [
                RateLimitBucket(
                    group: .general,
                    window: .fiveHour,
                    label: "5 hour usage limit",
                    remainingPercent: remaining,
                    usedPercent: 100 - remaining,
                    resetAt: nil,
                    resetLabel: nil,
                    windowDurationMins: 300
                )
            ],
            credit: nil,
            lastUpdated: Date(timeIntervalSinceNow: -minutesAgo * 60),
            sourceStatus: .liveStructured,
            sourceDescription: "test"
        )
    }
}
