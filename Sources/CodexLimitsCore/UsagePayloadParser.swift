import Foundation

public enum UsagePayloadParser {
    public static func parse(data: Data, sourceStatus: SourceStatus, sourceDescription: String) throws -> RateLimitSnapshot {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let snapshot = parse(json: json, sourceStatus: sourceStatus, sourceDescription: sourceDescription) else {
            throw CodexUsageError.parseFailed("No Codex rate-limit buckets found in payload.")
        }
        return snapshot
    }

    public static func parse(json: Any, sourceStatus: SourceStatus, sourceDescription: String) -> RateLimitSnapshot? {
        if let backendSnapshot = parseBackendUsagePayload(json, sourceStatus: sourceStatus, sourceDescription: sourceDescription) {
            return backendSnapshot
        }

        let entries = collectEntries(from: json)
        var buckets: [RateLimitBucket] = []

        for entry in entries {
            guard entry["limitName"] != nil || entry["limit_name"] != nil || entry["model"] != nil || entry["slug"] != nil || entry["name"] != nil else {
                continue
            }
            let rawLimitName = string(in: entry, keys: ["limitName", "limit_name", "model", "slug", "name"])
            let group: RateLimitGroup = rawLimitName == RateLimitGroup.spark.rawValue ? .spark : .general
            let bucketContainers = collectBucketObjects(from: entry)
            for bucket in bucketContainers {
                guard let window = window(from: bucket) else { continue }
                let used = double(in: bucket, keys: ["usedPercent", "used_percent", "usagePercent", "usage_percent"])
                let remaining = double(in: bucket, keys: ["remainingPercent", "remaining", "remaining_percent"])
                    ?? used.map { max(0, min(100, 100 - $0)) }
                let resetValue = bucket["resetsAt"] ?? bucket["resets_at"] ?? bucket["resetAt"] ?? bucket["reset_at"]
                buckets.append(RateLimitBucket(
                    group: group,
                    window: window,
                    label: window == .fiveHour ? "5 hour usage limit" : "Weekly usage limit",
                    remainingPercent: remaining,
                    usedPercent: used,
                    resetAt: date(from: resetValue),
                    resetLabel: string(in: bucket, keys: ["resetLabel", "reset_label"]),
                    windowDurationMins: int(in: bucket, keys: ["windowDurationMins", "window_duration_mins", "durationMins", "windowMins"])
                ))
            }
        }

        if buckets.isEmpty {
            buckets = parseFlatBuckets(from: json)
        }

        guard !buckets.isEmpty else { return nil }
        buckets = deduplicated(buckets)
        return RateLimitSnapshot(
            buckets: buckets.sorted { $0.id < $1.id },
            credit: credit(from: json),
            lastUpdated: Date(),
            sourceStatus: sourceStatus,
            sourceDescription: sourceDescription
        )
    }

    private static func parseBackendUsagePayload(_ json: Any, sourceStatus: SourceStatus, sourceDescription: String) -> RateLimitSnapshot? {
        guard let object = json as? [String: Any] else { return nil }
        var buckets: [RateLimitBucket] = []

        if let rateLimit = unboxObject(object["rate_limit"]) {
            buckets.append(contentsOf: backendBuckets(from: rateLimit, group: .general))
        }

        if let additional = unboxArray(object["additional_rate_limits"]) {
            for entry in additional {
                let feature = string(in: entry, keys: ["metered_feature", "meteredFeature", "limit_name", "limitName"])
                let group: RateLimitGroup = feature == RateLimitGroup.spark.rawValue ? .spark : .general
                if let rateLimit = unboxObject(entry["rate_limit"]) {
                    buckets.append(contentsOf: backendBuckets(from: rateLimit, group: group))
                }
            }
        }

        guard !buckets.isEmpty else { return nil }
        return RateLimitSnapshot(
            buckets: deduplicated(buckets).sorted { $0.id < $1.id },
            credit: backendCredit(from: object) ?? credit(from: object),
            lastUpdated: Date(),
            sourceStatus: sourceStatus,
            sourceDescription: sourceDescription
        )
    }

    private static func backendBuckets(from rateLimit: [String: Any], group: RateLimitGroup) -> [RateLimitBucket] {
        var buckets: [RateLimitBucket] = []
        if let primary = unboxObject(rateLimit["primary_window"]) {
            buckets.append(backendBucket(from: primary, group: group, window: .fiveHour))
        }
        if let secondary = unboxObject(rateLimit["secondary_window"]) {
            buckets.append(backendBucket(from: secondary, group: group, window: .weekly))
        }
        return buckets
    }

    private static func backendBucket(from windowObject: [String: Any], group: RateLimitGroup, window: RateLimitWindow) -> RateLimitBucket {
        let used = double(in: windowObject, keys: ["used_percent", "usedPercent"])
        let durationSeconds = int(in: windowObject, keys: ["limit_window_seconds", "limitWindowSeconds"])
        let durationMins = durationSeconds.map { max(1, ($0 + 59) / 60) }
        return RateLimitBucket(
            group: group,
            window: window,
            label: window == .fiveHour ? "5 hour usage limit" : "Weekly usage limit",
            remainingPercent: used.map { max(0, min(100, 100 - $0)) },
            usedPercent: used,
            resetAt: date(from: windowObject["reset_at"] ?? windowObject["resetAt"]),
            resetLabel: nil,
            windowDurationMins: durationMins
        )
    }

    private static func backendCredit(from object: [String: Any]) -> CreditStatus? {
        guard let details = unboxObject(object["credits"]) else { return nil }
        let balance = double(in: details, keys: ["balance"])
        let unlimited = bool(in: details, keys: ["unlimited"]) ?? false
        let hasCredits = bool(in: details, keys: ["has_credits", "hasCredits"]) ?? (balance != nil || unlimited)
        return CreditStatus(balance: balance, unlimited: unlimited, available: hasCredits || unlimited || balance != nil)
    }

    private static func collectEntries(from json: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []
        walk(json) { object in
            if object["rateLimitStatus"] != nil {
                appendEntryObjects(from: object["rateLimitStatus"], to: &result)
            }
            if object["rate_limit_status"] != nil {
                appendEntryObjects(from: object["rate_limit_status"], to: &result)
            }
            if object["limitName"] != nil || object["limit_name"] != nil {
                result.append(object)
            }
        }
        return result
    }

    private static func deduplicated(_ buckets: [RateLimitBucket]) -> [RateLimitBucket] {
        var seen: Set<String> = []
        var result: [RateLimitBucket] = []
        for bucket in buckets {
            guard !seen.contains(bucket.id) else { continue }
            seen.insert(bucket.id)
            result.append(bucket)
        }
        return result
    }

    private static func appendEntryObjects(from value: Any?, to result: inout [[String: Any]]) {
        if let array = value as? [[String: Any]] {
            result.append(contentsOf: array)
        } else if let object = value as? [String: Any] {
            for (_, child) in object {
                if let childObject = child as? [String: Any] {
                    result.append(childObject)
                }
            }
        }
    }

    private static func collectBucketObjects(from entry: [String: Any]) -> [[String: Any]] {
        if let buckets = entry["buckets"] as? [[String: Any]] {
            return buckets
        }
        if let bucket = entry["bucket"] as? [String: Any] {
            return [bucket]
        }
        return [entry]
    }

    private static func parseFlatBuckets(from json: Any) -> [RateLimitBucket] {
        var buckets: [RateLimitBucket] = []
        walk(json) { object in
            guard let window = window(from: object) else { return }
            let rawName = string(in: object, keys: ["limitName", "limit_name", "model", "slug", "name"])
            let group: RateLimitGroup = rawName == RateLimitGroup.spark.rawValue ? .spark : .general
            let used = double(in: object, keys: ["usedPercent", "used_percent", "usagePercent", "usage_percent"])
            let remaining = double(in: object, keys: ["remainingPercent", "remaining", "remaining_percent"])
                ?? used.map { max(0, min(100, 100 - $0)) }
            guard remaining != nil || used != nil else { return }
            buckets.append(RateLimitBucket(
                group: group,
                window: window,
                label: window == .fiveHour ? "5 hour usage limit" : "Weekly usage limit",
                remainingPercent: remaining,
                usedPercent: used,
                resetAt: date(from: object["resetsAt"] ?? object["resets_at"] ?? object["resetAt"] ?? object["reset_at"]),
                resetLabel: string(in: object, keys: ["resetLabel", "reset_label"]),
                windowDurationMins: int(in: object, keys: ["windowDurationMins", "window_duration_mins", "durationMins", "windowMins"])
            ))
        }
        return buckets
    }

    private static func window(from object: [String: Any]) -> RateLimitWindow? {
        if let duration = int(in: object, keys: ["windowDurationMins", "window_duration_mins", "durationMins", "windowMins"]) {
            return duration < 1_440 ? .fiveHour : .weekly
        }
        let label = (string(in: object, keys: ["label", "window", "type", "name"]) ?? "").lowercased()
        if label.contains("weekly") || label.contains("week") { return .weekly }
        if label.contains("5") || label.contains("hour") || label.contains("five") { return .fiveHour }
        return nil
    }

    private static func credit(from json: Any) -> CreditStatus? {
        var found: CreditStatus?
        walk(json) { object in
            guard found == nil else { return }
            if let balance = double(in: object, keys: ["balance", "creditBalance", "credit_balance"]) {
                found = CreditStatus(balance: balance, unlimited: bool(in: object, keys: ["unlimited"]) ?? false, available: true)
            } else if bool(in: object, keys: ["unlimited"]) == true {
                found = CreditStatus(balance: nil, unlimited: true, available: true)
            }
        }
        return found
    }

    private static func walk(_ value: Any, objectHandler: ([String: Any]) -> Void) {
        if let object = value as? [String: Any] {
            objectHandler(object)
            for child in object.values {
                walk(child, objectHandler: objectHandler)
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(child, objectHandler: objectHandler)
            }
        }
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func double(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if let value = object[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func int(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func bool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
        }
        return nil
    }

    private static func unboxObject(_ value: Any?) -> [String: Any]? {
        if value is NSNull { return nil }
        if let object = value as? [String: Any] { return object }
        return nil
    }

    private static func unboxArray(_ value: Any?) -> [[String: Any]]? {
        if value is NSNull { return nil }
        return value as? [[String: Any]]
    }

    private static func date(from value: Any?) -> Date? {
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        }
        if let value = value as? Int {
            let numeric = Double(value)
            return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1_000 : numeric)
        }
        guard let value = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return nil
    }
}
