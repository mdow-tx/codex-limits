import Foundation

public struct RateLimitGroup: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let general = RateLimitGroup(rawValue: "general")
    public static let spark = RateLimitGroup(rawValue: "gpt-5.3-codex-spark")

    public var displayName: String {
        if self == .general { return "General" }
        if self == .spark { return "GPT-5.3-Codex-Spark" }
        if rawValue.localizedCaseInsensitiveContains("gpt") {
            return rawValue.replacingOccurrences(of: "_", with: "-")
        }
        return rawValue
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }

    public var sortKey: String {
        if self == .general { return "0-\(rawValue)" }
        if self == .spark { return "1-\(rawValue)" }
        return "2-\(displayName)"
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
    public let planType: String?
    public let rateLimitReachedType: String?
    public let spendControl: SpendControlStatus?

    public init(
        buckets: [RateLimitBucket],
        credit: CreditStatus?,
        lastUpdated: Date,
        sourceStatus: SourceStatus,
        sourceDescription: String,
        planType: String? = nil,
        rateLimitReachedType: String? = nil,
        spendControl: SpendControlStatus? = nil
    ) {
        self.buckets = buckets
        self.credit = credit
        self.lastUpdated = lastUpdated
        self.sourceStatus = sourceStatus
        self.sourceDescription = sourceDescription
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControl = spendControl
    }
}

public struct SpendControlStatus: Codable, Equatable, Sendable {
    public let limit: String?
    public let used: String?
    public let remainingPercent: Double?
    public let resetAt: Date?

    public init(limit: String?, used: String?, remainingPercent: Double?, resetAt: Date?) {
        self.limit = limit
        self.used = used
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
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
