import CodexLimitsCore
import XCTest

final class ProviderRegressionTests: XCTestCase {
    func testScannerAcceptsSnakeCaseAndStopsAtCandidateLimit() {
        let payload = #"{"rate_limit":{"primary_window":{"used_percent":10}}}"#
        let candidates = JSONCandidateExtractor.extractCandidates(from: Data(String(repeating: payload, count: 100).utf8))
        XCTAssertEqual(candidates.count, 50)
        XCTAssertEqual(candidates.first, Data(payload.utf8))
    }

    func testScannerHandlesQuotedBracesAndMalformedPrefix() {
        let payload = #"{"rateLimit":"brace } and [ in string","remainingPercent":50}"#
        let candidates = JSONCandidateExtractor.extractCandidates(from: Data(("{]" + payload).utf8))
        XCTAssertEqual(candidates, [Data(payload.utf8)])
    }

    func testFallbackPreservesFailureAndDoesNotOverwriteSavedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
        let saved = RateLimitSnapshot(buckets: [], credit: nil, lastUpdated: Date(timeIntervalSince1970: 100),
                                     sourceStatus: .liveStructured, sourceDescription: "saved")
        try store.save(saved)
        let chain = ProviderChain(providers: [FailingProvider()], store: store)
        let result = try await chain.fetchSnapshot()
        XCTAssertEqual(result.lastUpdated, saved.lastUpdated)
        XCTAssertEqual(result.sourceStatus, .cachedStructured)
        XCTAssertTrue(result.sourceDescription.contains("offline"))
        XCTAssertEqual(try store.load(), saved)
    }

    func testChromiumCacheUsesFileDateInsteadOfCurrentTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.log")
        try Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#.utf8).write(to: file)
        let date = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let result = try await CodexCachedStateProvider(roots: [directory]).fetchSnapshot()
        XCTAssertEqual(result.lastUpdated.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(result.sourceStatus, .cachedStructured)
    }
}

private struct FailingProvider: CodexUsageProvider {
    let name = "test"
    func fetchSnapshot() async throws -> RateLimitSnapshot {
        throw CodexUsageError.unavailable("offline")
    }
}
