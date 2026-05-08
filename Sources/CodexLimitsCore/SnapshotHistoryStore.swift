import Foundation

public struct SnapshotHistoryStore: Sendable {
    public let fileURL: URL
    public let maxEntries: Int

    public init(fileURL: URL? = nil, maxEntries: Int = 1_000) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base
                .appendingPathComponent("Codex Limits", isDirectory: true)
                .appendingPathComponent("history.json")
        }
        self.maxEntries = maxEntries
    }

    public func load() throws -> [RateLimitSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.codexLimits.decode([RateLimitSnapshot].self, from: data)
    }

    public func append(_ snapshot: RateLimitSnapshot) throws {
        var history = try load()
        if history.last != snapshot {
            history.append(snapshot)
        }
        if history.count > maxEntries {
            history = Array(history.suffix(maxEntries))
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.codexLimits.encode(history)
        try data.write(to: fileURL, options: [.atomic])
    }
}
