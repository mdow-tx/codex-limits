import Foundation

public enum SnapshotFormatting {
    public static func menuTitle(for snapshot: RateLimitSnapshot?) -> String {
        guard let snapshot else { return "Codex ?" }
        guard let bucket = snapshot.buckets
            .filter({ $0.remainingPercent != nil })
            .min(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) })
        else {
            return "Codex ?"
        }

        let percent = Int((bucket.remainingPercent ?? 0).rounded())
        return "\(percent)%"
    }

    public static func resetText(for bucket: RateLimitBucket) -> String? {
        if let resetLabel = bucket.resetLabel, !resetLabel.isEmpty {
            return resetLabel
                .replacingOccurrences(of: "Resets ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let resetAt = bucket.resetAt else { return nil }
        if bucket.window == .weekly {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return formatter.string(from: resetAt)
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: resetAt)
    }

    public static func detailLine(for bucket: RateLimitBucket) -> String {
        let remaining = bucket.remainingPercent.map { "\(Int($0.rounded()))% left" } ?? "unknown"
        let reset = resetText(for: bucket).map { "resets \($0)" } ?? "reset unknown"
        return "\(bucket.group.displayName) \(bucket.window.displayName): \(remaining), \(reset)"
    }
}
