import Foundation

public enum RateLimitGroup: String, Codable, CaseIterable, Sendable {
    case general
    case spark = "gpt-5.3-codex-spark"

    public var displayName: String {
        switch self {
        case .general: "General"
        case .spark: "GPT-5.3-Codex-Spark"
        }
    }
}

public enum RateLimitWindow: String, Codable, CaseIterable, Sendable {
    case fiveHour
    case weekly

    public var displayName: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "Weekly"
        }
    }
}

public enum SourceStatus: String, Codable, Sendable {
    case liveStructured
    case cachedStructured
    case accessibility
    case unavailable
}

public struct RateLimitBucket: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(group.rawValue)-\(window.rawValue)" }
    public let group: RateLimitGroup
    public let window: RateLimitWindow
    public let label: String
    public let remainingPercent: Double?
    public let usedPercent: Double?
    public let resetAt: Date?
    public let resetLabel: String?
    public let windowDurationMins: Int?

    public init(
        group: RateLimitGroup,
        window: RateLimitWindow,
        label: String,
        remainingPercent: Double?,
        usedPercent: Double?,
        resetAt: Date?,
        resetLabel: String?,
        windowDurationMins: Int?
    ) {
        self.group = group
        self.window = window
        self.label = label
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.resetLabel = resetLabel
        self.windowDurationMins = windowDurationMins
    }
}

public struct CreditStatus: Codable, Equatable, Sendable {
    public let balance: Double?
    public let unlimited: Bool
    public let available: Bool

    public init(balance: Double?, unlimited: Bool, available: Bool) {
        self.balance = balance
        self.unlimited = unlimited
        self.available = available
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable {
    public let buckets: [RateLimitBucket]
    public let credit: CreditStatus?
    public let lastUpdated: Date
    public let sourceStatus: SourceStatus
    public let sourceDescription: String

    public init(
        buckets: [RateLimitBucket],
        credit: CreditStatus?,
        lastUpdated: Date,
        sourceStatus: SourceStatus,
        sourceDescription: String
    ) {
        self.buckets = buckets
        self.credit = credit
        self.lastUpdated = lastUpdated
        self.sourceStatus = sourceStatus
        self.sourceDescription = sourceDescription
    }
}

public enum CodexUsageError: LocalizedError, Sendable {
    case unavailable(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .parseFailed(let message):
            message
        }
    }
}
