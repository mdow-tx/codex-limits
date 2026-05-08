import Foundation

public enum JSONCandidateExtractor {
    public static func extractCandidates(from data: Data) -> [Data] {
        let text = String(decoding: data, as: UTF8.self)
        guard text.localizedCaseInsensitiveContains("rateLimit")
            || text.localizedCaseInsensitiveContains("usage")
            || text.localizedCaseInsensitiveContains("remaining")
        else {
            return []
        }

        var candidates: [Data] = []
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices where scalars[index] == "{" || scalars[index] == "[" {
            if let end = balancedEnd(in: scalars, from: index) {
                let candidate = String(String.UnicodeScalarView(scalars[index...end]))
                if candidate.localizedCaseInsensitiveContains("rateLimit")
                    || candidate.localizedCaseInsensitiveContains("remainingPercent")
                    || candidate.localizedCaseInsensitiveContains("usedPercent") {
                    candidates.append(Data(candidate.utf8))
                }
            }
        }
        return Array(candidates.prefix(50))
    }

    private static func balancedEnd(in scalars: [UnicodeScalar], from start: Int) -> Int? {
        var stack: [UnicodeScalar] = []
        var inString = false
        var escaping = false

        for index in start..<min(scalars.count, start + 500_000) {
            let scalar = scalars[index]
            if inString {
                if escaping {
                    escaping = false
                } else if scalar == "\\" {
                    escaping = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            if scalar == "\"" {
                inString = true
            } else if scalar == "{" {
                stack.append("}")
            } else if scalar == "[" {
                stack.append("]")
            } else if scalar == "}" || scalar == "]" {
                guard stack.popLast() == scalar else { return nil }
                if stack.isEmpty { return index }
            }
        }
        return nil
    }
}
