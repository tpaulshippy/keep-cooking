// Smidgen — Lane 4 Cook: time-string → multi-timer parser (pure)
// Turns free-text step strings into zero or more timers, e.g.
//   "bake 12-15 min, rest 1 hr" -> [12..15min upper=15min "bake", 1hr "rest"]
// Rules:
//   - Ranges use the UPPER bound ("12-15 min" -> 15 min).
//   - Units: hr/hrs/hour(s) = 3600s, min/mins/minute(s) = 60s, sec(s)/second(s) = 1s.
//   - The label is the closest preceding verb-ish word run before the duration
//     (up to 2 words), falling back to the whole step prefix trimmed to 24 chars.
//   - No force-unwrap; returns [] when nothing parses.

import Foundation

/// One parsed timer: fire after `seconds` with a human label.
public struct ParsedTimer: Sendable, Hashable, Equatable {
    public var seconds: Int
    public var label: String
    public init(seconds: Int, label: String) {
        self.seconds = seconds
        self.label = label
    }
}

/// Parses all durations out of a step text string.
public func parseTimers(from text: String) -> [ParsedTimer] {
    // Matches: <number>[-–<number>] <unit>, e.g. "12-15 min", "1 hr", "30 seconds".
    let pattern = #"(\d+(?:\.\d+)?)\s*(?:[-–]\s*(\d+(?:\.\d+)?))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return []
    }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var out: [ParsedTimer] = []
    for m in matches {
        let firstStr = ns.substring(with: m.range(at: 1))
        let secondRange = m.range(at: 2)
        let numStr = secondRange.location != NSNotFound ? ns.substring(with: secondRange) : firstStr
        let unitStr = ns.substring(with: m.range(at: 3)).lowercased()
        guard let num = Double(numStr) else { continue }
        let multiplier: Double
        if unitStr.hasPrefix("h") { multiplier = 3600 }
        else if unitStr.hasPrefix("min") || unitStr == "m" { multiplier = 60 }
        else if unitStr.hasPrefix("sec") || unitStr == "s" { multiplier = 1 }
        else if unitStr.hasPrefix("m") { multiplier = 60 } // "m" shorthand
        else { continue }
        let seconds = Int((num * multiplier).rounded())
        guard seconds > 0 else { continue }
        let label = labelBefore(matchRange: m.range, in: text)
        out.append(ParsedTimer(seconds: seconds, label: label))
    }
    return out
}

/// Best-effort label: last ≤2 words before the duration match.
private func labelBefore(matchRange: NSRange, in text: String) -> String {
    let ns = text as NSString
    let prefix = ns.substring(to: matchRange.location)
    // Split on anything that isn't a letter; drop empties.
    let words = prefix.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    let tail = words.suffix(2).joined(separator: " ")
    if !tail.isEmpty { return tail }
    // Fallback: trimmed prefix, capped at 24 chars.
    let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Timer" }
    return String(trimmed.suffix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
}
