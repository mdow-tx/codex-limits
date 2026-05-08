import Foundation

public enum AccessibilityTextParser {
    public static func parse(text: String) -> RateLimitSnapshot? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var buckets: [RateLimitBucket] = []
        var currentGroup: RateLimitGroup = .general
        var pendingWindow: RateLimitWindow?
        var pendingReset: String?

        for line in lines {
            let lower = line.lowercased()
            if lower.contains("spark") {
                currentGroup = .spark
            } else if lower.contains("general usage") || lower == "rate limits remaining" {
                currentGroup = .general
            }

            if lower.contains("5 hour") || lower == "5h" {
                pendingWindow = .fiveHour
            } else if lower.contains("weekly") {
                pendingWindow = .weekly
            }

            if lower.hasPrefix("resets ") {
                pendingReset = line.replacingOccurrences(of: "Resets ", with: "")
            }

            if let percent = percent(from: line), let window = pendingWindow {
                buckets.append(RateLimitBucket(
                    group: currentGroup,
                    window: window,
                    label: window == .fiveHour ? "5 hour usage limit" : "Weekly usage limit",
                    remainingPercent: percent,
                    usedPercent: 100 - percent,
                    resetAt: nil,
                    resetLabel: pendingReset,
                    windowDurationMins: window == .fiveHour ? 300 : 10_080
                ))
                pendingWindow = nil
                pendingReset = nil
            }
        }

        guard !buckets.isEmpty else { return nil }
        return RateLimitSnapshot(
            buckets: buckets,
            credit: nil,
            lastUpdated: Date(),
            sourceStatus: .accessibility,
            sourceDescription: "Read from Codex accessibility text"
        )
    }

    private static func percent(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else {
            return nil
        }
        return Double(line[range].replacingOccurrences(of: "%", with: ""))
    }
}
