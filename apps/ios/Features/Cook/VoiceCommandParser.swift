// Keep Cooking — Lane 10 Voice (Option A): hands-free cook command parser (pure)
// Pure Swift, no AV/Speech imports, testable. The caller (VoiceCookManager /
// CookModeView UI lane) owns microphone gating, mid-sentence filtering, and
// side effects — this file only maps one standalone utterance to a command.
//
// Conventions:
//   - Input is a raw transcript; normalization (lowercase, trim, trailing
//     period strip) happens inside `parseVoiceCommand`.
//   - A leading "smidgen" / "hey smidgen" wake-word prefix is stripped before
//     matching. Ambiguous utterances ("i'm done", "goodbye", "what was that?",
//     "come again", "cancel", "halve it", "double it") are ONLY honored when
//     that prefix was present; bare they parse as `.unknown`.

import Foundation

// MARK: - Command

public enum VoiceCommand: Equatable {
    case next
    case previous
    case repeatStep
    /// 1-based step number; `VoiceCommand.lastStep` (-1) means the last step.
    case goToStep(Int)
    case startOver
    case readIngredients
    case ingredientAmount(name: String)
    case crossOff(name: String)
    case uncross(name: String)
    case doubleScale
    case halveScale
    case resetScale
    case addToList(listName: String?)
    case startTimer(seconds: Int?, label: String?)
    case stopSpeaking
    case stopCooking
    case unknown

    /// Sentinel for `.goToStep` meaning "the last step".
    public static let lastStep = -1
}

// MARK: - Normalization

/// Lowercases, trims, drops apostrophes ("i'm" == "im"), strips trailing
/// sentence punctuation, and collapses internal whitespace.
public func normalizeVoiceText(_ raw: String) -> String {
    var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    s = s.replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "`", with: "")
    while let last = s.last, ".!?".contains(last) { s.removeLast() }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Ingredient-name normalization shared with the fuzzy matcher: voice
/// normalization plus a leading "the" strip.
public func voiceNormalizedName(_ raw: String) -> String {
    var s = normalizeVoiceText(raw)
    if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
    return s
}

/// Strips a leading "smidgen" / "hey smidgen" wake-word prefix.
/// Returns the remainder plus whether the prefix was present.
func stripVoiceWakeWord(_ text: String) -> (utterance: String, hadPrefix: Bool) {
    for prefix in ["hey smidgen", "smidgen"] {
        if text == prefix { return ("", true) }
        if text.hasPrefix(prefix + " ") {
            return (String(text.dropFirst(prefix.count + 1)), true)
        }
        if text.hasPrefix(prefix + ",") {
            let rest = String(text.dropFirst(prefix.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (rest, true)
        }
    }
    return (text, false)
}

// MARK: - Number words

private let voiceOnes: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19, "twenty": 20,
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
    "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
    "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
    "nineteenth": 19, "twentieth": 20,
]

private let voiceTens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
]

/// Number words one–twenty (plus ordinals and tens compounds up to 99 for
/// timers, e.g. "twenty five"). Returns nil when the token isn't a number.
public func voiceNumberValue(_ token: String) -> Int? {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.isEmpty { return nil }
    if let n = Int(t) { return n }
    if let v = voiceOnes[t] { return v }
    if let v = voiceTens[t] { return v }
    let parts = t.split(separator: " ").map(String.init)
    guard parts.count == 2, let tens = voiceTens[parts[0]], let ones = voiceOnes[parts[1]], ones < 10 else {
        return nil
    }
    return tens + ones
}

// MARK: - Fuzzy ingredient match

/// Best fuzzy match for a spoken ingredient name against candidate labels.
/// Matches on normalized containment first, then token overlap. Returns the
/// original (non-normalized) candidate string, or nil when nothing matches.
public func fuzzyVoiceMatch(_ query: String, candidates: [String]) -> String? {
    let q = voiceNormalizedName(query)
    guard !q.isEmpty else { return nil }
    let qTokens = Set(q.split(separator: " ").map(String.init))
    var bestCandidate: String?
    var bestScore = 0.0
    var bestLength = Int.max
    for candidate in candidates {
        let c = voiceNormalizedName(candidate)
        guard !c.isEmpty else { continue }
        let score: Double
        if c == q {
            score = 3
        } else if c.contains(q) || q.contains(c) {
            score = 2
        } else {
            let cTokens = Set(c.split(separator: " ").map(String.init))
            let overlap = qTokens.intersection(cTokens).count
            guard overlap > 0 else { continue }
            score = Double(overlap) / Double(max(qTokens.count, 1))
        }
        if score > bestScore || (score == bestScore && c.count < bestLength) {
            bestScore = score
            bestLength = c.count
            bestCandidate = candidate
        }
    }
    return bestCandidate
}

// MARK: - Timer durations in voice text

private func voiceSeconds(num: Double, unit: String) -> Int? {
    let multiplier: Double
    if unit.hasPrefix("h") { multiplier = 3600 }
    else if unit.hasPrefix("m") { multiplier = 60 }
    else if unit.hasPrefix("s") { multiplier = 1 }
    else { return nil }
    let seconds = Int((num * multiplier).rounded())
    return seconds > 0 ? seconds : nil
}

private func voiceCompoundWordNumber(_ words: [String]) -> Double? {
    if words.isEmpty { return nil }
    if words.count == 1 {
        let w = words[0]
        if w == "a" || w == "an" { return 1 }
        if let n = Int(w) { return Double(n) }
        if let v = voiceNumberValue(w) { return Double(v) }
        return nil
    }
    // Tens compound ("twenty five").
    if words.count == 2, let tens = voiceTens[words[0]], let ones = voiceOnes[words[1]], ones < 10 {
        return Double(tens + ones)
    }
    return nil
}

/// Finds the first duration in free text. Numeric forms use the UPPER bound
/// for ranges ("12-15 minutes" -> 15 min), matching `parseTimers`.
private func voiceTimerSeconds(in text: String) -> Int? {
    let pattern = #"(\d+(?:\.\d+)?)\s*(?:(?:[-–]|to)\s*(\d+(?:\.\d+)?))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        let range = NSRange(text.startIndex..., in: text)
        if let m = regex.firstMatch(in: text, range: range) {
            let ns = text as NSString
            let secondRange = m.range(at: 2)
            let numStr = secondRange.location != NSNotFound
                ? ns.substring(with: secondRange)
                : ns.substring(with: m.range(at: 1))
            let unit = ns.substring(with: m.range(at: 3)).lowercased()
            if let num = Double(numStr) { return voiceSeconds(num: num, unit: unit) }
        }
    }
    // Number-word forms ("ten minutes", "an hour", "twenty five seconds").
    let hourWords: Set<String> = ["hour", "hours", "hr", "hrs"]
    let minuteWords: Set<String> = ["minute", "minutes", "min", "mins"]
    let secondWords: Set<String> = ["second", "seconds", "sec", "secs"]
    let tokens = text.split(separator: " ").map(String.init)
    for (i, token) in tokens.enumerated() {
        let isUnit = hourWords.contains(token)
            || minuteWords.contains(token)
            || secondWords.contains(token)
        guard isUnit else { continue }
        let start = max(0, i - 2)
        let window = Array(tokens[start..<i])
        // Try the longest trailing slice first ("twenty five"), then shorter.
        for length in stride(from: window.count, through: 1, by: -1) {
            let slice = Array(window.suffix(length))
            if let num = voiceCompoundWordNumber(slice) {
                return voiceSeconds(num: num, unit: token)
            }
        }
    }
    return nil
}

// MARK: - Parser

/// Parses one standalone voice utterance into a `VoiceCommand`.
/// Mid-sentence input ("please tell me the next step") stays `.unknown` —
/// the caller gates on standalone utterances.
public func parseVoiceCommand(_ transcript: String) -> VoiceCommand {
    let (text, hadSmidgen) = stripVoiceWakeWord(normalizeVoiceText(transcript))
    if text.isEmpty { return .unknown }

    switch text {
    case "next", "next step", "go next", "go forward", "move on":
        return .next
    case "previous", "previous step", "go back", "back", "last one":
        return .previous
    case "repeat", "repeat step", "repeat that", "say that again",
         "read that again", "read it again", "read this step":
        return .repeatStep
    case "start over", "start from the beginning", "restart",
         "restart the recipe", "start from the start":
        return .startOver
    case "read ingredients", "read the ingredients", "list ingredients",
         "list the ingredients", "what are the ingredients":
        return .readIngredients
    case "double the recipe", "double recipe", "double the scale", "double scale":
        return .doubleScale
    case "halve the recipe", "halve recipe", "halve the scale", "halve scale":
        return .halveScale
    case "reset the recipe", "reset recipe", "reset the scale", "reset scale",
         "reset servings", "reset the servings":
        return .resetScale
    case "stop", "stop speaking", "stop reading", "stop talking",
         "be quiet", "quiet":
        return .stopSpeaking
    case "stop cooking", "exit cooking", "leave cook mode",
         "finish cooking", "quit cooking", "end cooking":
        return .stopCooking
    case "start the timer", "start timer", "start a timer",
         "set the timer", "set timer", "set a timer":
        return .startTimer(seconds: nil, label: nil)
    default:
        break
    }

    // "go to step 3" / "go to the last step" / "go to step three".
    if let step = parseVoiceGoToStep(text) { return step }

    // "start a timer for N minutes/hours/seconds" (also "set ...").
    if let timer = parseVoiceTimer(text) { return timer }

    // "how much <x> do i need".
    if let amount = parseVoiceIngredientAmount(text) { return amount }

    // "cross off (the) <x>" / "check off (the) <x>".
    if let cross = parseVoiceCrossOff(text) { return cross }

    // "uncross (the) <x>" / "uncheck ...".
    if let uncross = parseVoiceUncross(text) { return uncross }

    // "add (the) ingredients to my [name] list".
    if let add = parseVoiceAddToList(text) { return add }

    // Ambiguous utterances: ONLY with the "smidgen" prefix.
    if hadSmidgen {
        switch text {
        case "im done":
            return .next
        case "goodbye", "cancel":
            return .stopCooking
        case "what was that":
            return .repeatStep
        case "come again":
            return .repeatStep
        case "halve it":
            return .halveScale
        case "double it":
            return .doubleScale
        default:
            break
        }
    }

    return .unknown
}

// MARK: - Pattern matchers (private)

private func parseVoiceGoToStep(_ text: String) -> VoiceCommand? {
    guard text.hasPrefix("go to ") else { return nil }
    var rest = String(text.dropFirst("go to ".count))
    if rest.hasPrefix("the ") { rest = String(rest.dropFirst("the ".count)) }
    if rest == "last" || rest == "last step" { return .goToStep(VoiceCommand.lastStep) }
    guard rest.hasPrefix("step ") else { return nil }
    let token = String(rest.dropFirst("step ".count)).trimmingCharacters(in: .whitespaces)
    if token == "last" { return .goToStep(VoiceCommand.lastStep) }
    guard let n = voiceNumberValue(token), n > 0 else { return nil }
    return .goToStep(n)
}

private func parseVoiceTimer(_ text: String) -> VoiceCommand? {
    let prefixes = ["start a timer", "start the timer", "start timer",
                    "set a timer", "set the timer", "set timer"]
    var rest: String?
    for prefix in prefixes where text == prefix || text.hasPrefix(prefix + " ") {
        rest = text == prefix ? "" : String(text.dropFirst(prefix.count + 1))
        break
    }
    guard var remainder = rest else { return nil }
    if remainder.hasPrefix("for ") { remainder = String(remainder.dropFirst("for ".count)) }
    remainder = remainder.trimmingCharacters(in: .whitespaces)
    guard !remainder.isEmpty else { return .startTimer(seconds: nil, label: nil) }
    guard let seconds = voiceTimerSeconds(in: remainder) else { return nil }
    return .startTimer(seconds: seconds, label: nil)
}

private func parseVoiceIngredientAmount(_ text: String) -> VoiceCommand? {
    guard text.hasPrefix("how much ") else { return nil }
    let suffixes = ["do i need", "do we need", "will i need"]
    var middle: String?
    for suffix in suffixes where text.hasSuffix(suffix) {
        middle = String(text.dropFirst("how much ".count).dropLast(suffix.count))
        break
    }
    guard var name = middle?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
    if name.hasPrefix("of ") { name = String(name.dropFirst("of ".count)) }
    name = voiceNormalizedName(name)
    guard !name.isEmpty else { return nil }
    return .ingredientAmount(name: name)
}

private func parseVoiceCrossOff(_ text: String) -> VoiceCommand? {
    for prefix in ["cross off ", "check off "] where text.hasPrefix(prefix) {
        let name = voiceNormalizedName(String(text.dropFirst(prefix.count)))
        guard !name.isEmpty else { return nil }
        return .crossOff(name: name)
    }
    return nil
}

private func parseVoiceUncross(_ text: String) -> VoiceCommand? {
    for prefix in ["uncross off ", "uncheck off ", "uncross ", "uncheck "]
        where text.hasPrefix(prefix) {
        let name = voiceNormalizedName(String(text.dropFirst(prefix.count)))
        guard !name.isEmpty else { return nil }
        return .uncross(name: name)
    }
    return nil
}

private func parseVoiceAddToList(_ text: String) -> VoiceCommand? {
    var rest: String?
    for prefix in ["add the ingredients to my ", "add ingredients to my "] where text.hasPrefix(prefix) {
        rest = String(text.dropFirst(prefix.count))
        break
    }
    guard let remainder = rest else { return nil }
    if remainder == "list" { return .addToList(listName: nil) }
    guard remainder.hasSuffix(" list") else { return nil }
    let name = String(remainder.dropLast(" list".count)).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    return .addToList(listName: name)
}
