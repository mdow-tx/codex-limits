import Foundation

public enum JSONCandidateExtractor {
    public static func extractCandidates(from data: Data) -> [Data] {
        let bytes = Array(data.prefix(20_000_000))
        var candidates: [Data] = []
        var stack: [UInt8] = []
        var start = 0
        var inString = false
        var escaping = false
        for (index, byte) in bytes.enumerated() {
            if !stack.isEmpty && (index - start >= 500_000 || stack.count > 128) {
                stack.removeAll(keepingCapacity: true)
                inString = false
                escaping = false
            }
            if stack.isEmpty {
                guard byte == 123 || byte == 91 else { continue }
                start = index
                stack.append(byte == 123 ? 125 : 93)
                continue
            }
            if inString {
                if escaping { escaping = false }
                else if byte == 92 { escaping = true }
                else if byte == 34 { inString = false }
                continue
            }
            if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 { stack.append(byte == 123 ? 125 : 93) }
            else if byte == 125 || byte == 93 {
                guard stack.popLast() == byte else {
                    stack.removeAll(keepingCapacity: true)
                    continue
                }
                if stack.isEmpty {
                    let candidate = Data(bytes[start...index])
                    let text = String(decoding: candidate, as: UTF8.self).lowercased()
                    if ["ratelimit", "rate_limit", "remainingpercent", "usedpercent"].contains(where: text.contains) {
                        candidates.append(candidate)
                        if candidates.count == 50 { break }
                    }
                }
            }
        }
        return candidates
    }
}
