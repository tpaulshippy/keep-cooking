// Keep Cooking — Lane 10 Voice (Option A): hands-free cook command parser (pure)
// Pure Swift, no AV/Speech imports, testable. The caller (VoiceCookManager /
// CookModeView UI lane) owns microphone gating, mid-sentence filtering, and
// side effects — this file only maps one standalone utterance to a command.
//
// Conventions:
//   - Input is a raw transcript; normalization (lowercase, trim, trailing
//     period strip) happens inside `parseVoiceCommand`.
//   - A leading "keep cooking" / "hey keep cooking" wake-word prefix is stripped before
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
        .replacingOccurrences(of: "\u{2019}", with: "")
        .replacingOccurrences(of: "\u{2018}", with: "")
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

/// Strips a leading "keep cooking" / "hey keep cooking" wake-word prefix.
/// Returns the remainder plus whether the prefix was present.
func stripVoiceWakeWord(_ text: String) -> (utterance: String, hadPrefix: Bool) {
    for prefix in ["hey keep cooking", "keep cooking"] {
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
/// Token-boundary-aware scoring: normalized exact equality outranks exact
/// token overlap, which outranks token-boundary phrase containment.
/// Within a tier, the candidate with the most matched tokens wins, then the
/// longest matched span. Returns the original (non-normalized) candidate
/// string, or nil when nothing matches — including when the top two
/// candidates tie (ambiguous; the caller replies with disambiguation).
public func fuzzyVoiceMatch(_ query: String, candidates: [String]) -> String? {
    let q = voiceNormalizedName(query)
    guard !q.isEmpty else { return nil }
    let qTokens = q.split(separator: " ").map(String.init)
    let qSet = Set(qTokens)
    // (tier, matchedTokens, matchedSpan, order) — higher wins.
    var bestKey: (Int, Int, Int)?
    var bestCandidate: String?
    var bestCount = 0
    for candidate in candidates {
        let c = voiceNormalizedName(candidate)
        guard !c.isEmpty else { continue }
        let cTokens = c.split(separator: " ").map(String.init)
        let key: (Int, Int, Int)?
        if c == q {
            key = (3, qTokens.count, q.count)
        } else {
            let cSet = Set(cTokens)
            let overlap = qSet.intersection(cSet)
            if !overlap.isEmpty {
                let span = overlap.reduce(0) { $0 + $1.count }
                key = (2, overlap.count, span)
            } else if voiceTokenBoundaryContains(c, q) || voiceTokenBoundaryContains(q, c) {
                // Phrase containment aligned to token boundaries only, so
                // "our" never matches "flour". Span = needle length.
                let needle = c.count > q.count ? q : c
                key = (1, 1, needle.count)
            } else {
                continue
            }
        }
        guard let k = key else { continue }
        if bestKey == nil || k > bestKey! {
            bestKey = k
            bestCandidate = candidate
            bestCount = 1
        } else if k == bestKey! {
            bestCount += 1
        }
    }
    guard bestCount == 1 else { return nil }
    return bestCandidate
}

/// Ambiguity signal for a spoken ingredient name. Mirrors `fuzzyVoiceMatch`
/// scoring but reports whether the top score is shared by 2+ candidates.
/// The manager lane uses this: `fuzzyVoiceMatch` returns nil on ties AND on
/// no-match, so callers must check this (not `fuzzyVoiceMatch(...) != nil`)
/// to decide between "Which <name>?" (ambiguous) and "I don't see ..." .
public func isFuzzyVoiceMatchAmbiguous(_ query: String, candidates: [String]) -> Bool {
    let q = voiceNormalizedName(query)
    guard !q.isEmpty else { return false }
    let qTokens = q.split(separator: " ").map(String.init)
    let qSet = Set(qTokens)
    var bestKey: (Int, Int, Int)?
    var bestCount = 0
    for candidate in candidates {
        let c = voiceNormalizedName(candidate)
        guard !c.isEmpty else { continue }
        let cTokens = c.split(separator: " ").map(String.init)
        let key: (Int, Int, Int)?
        if c == q {
            key = (3, qTokens.count, q.count)
        } else {
            let cSet = Set(cTokens)
            let overlap = qSet.intersection(cSet)
            if !overlap.isEmpty {
                let span = overlap.reduce(0) { $0 + $1.count }
                key = (2, overlap.count, span)
            } else if voiceTokenBoundaryContains(c, q) || voiceTokenBoundaryContains(q, c) {
                let needle = c.count > q.count ? q : c
                key = (1, 1, needle.count)
            } else {
                continue
            }
        }
        guard let k = key else { continue }
        if bestKey == nil || k > bestKey! {
            bestKey = k
            bestCount = 1
        } else if k == bestKey! {
            bestCount += 1
        }
    }
    return bestCount > 1
}

/// Token-boundary containment: `needle` appears in `haystack` as a whole
/// phrase of tokens (hyphens/slashes count as boundaries).
private func voiceTokenBoundaryContains(_ haystack: String, _ needle: String) -> Bool {
    if haystack == needle { return true }
    func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "/", with: " ")
    }
    let h = norm(haystack)
    let n = norm(needle)
    if h == n { return true }
    return h.hasPrefix(n + " ") || h.hasSuffix(" " + n) || h.contains(" " + n + " ")
}

// MARK: - Timer durations in voice text

private func voiceSeconds(num: Double, unit: String) -> Int? {
    let multiplier: Double
    if unit.hasPrefix("h") { multiplier = 3600 }
    else if unit.hasPrefix("m") { multiplier = 60 }
    else if unit.hasPrefix("s") { multiplier = 1 }
    else { return nil }
    guard num.isFinite else { return nil }
    let raw = (num * multiplier).rounded()
    guard raw.isFinite, raw >= 1, raw <= 43200 else { return nil }
    return Int(raw)
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
    // General English number phrase (strict: ANY unhandled token rejects
    // the whole slice, so "one hundred" never degrades to a partial 1).
    // Supports ones/tens compounds plus hundred(s)/thousand(s), e.g.
    // "twenty five", "one hundred", "one hundred twenty five",
    // "two thousand three hundred", "a hundred". "and" is filler.
    var total = 0
    var current = 0
    var seenNumber = false
    for w in words {
        if w == "and" { continue }
        if w == "a" || w == "an" {
            current += 1
            seenNumber = true
        } else if let v = voiceOnes[w] {
            // Avoid double-counting tens compounds handled below; single
            // pass is fine since tens+ones are additive here too.
            current += v
            seenNumber = true
        } else if let v = voiceTens[w] {
            current += v
            seenNumber = true
        } else if w == "hundred" || w == "hundreds" {
            guard current > 0 else { return nil }
            current *= 100
            seenNumber = true
        } else if w == "thousand" || w == "thousands" {
            guard current > 0 else { return nil }
            total += current * 1000
            current = 0
            seenNumber = true
        } else if let n = Int(w) {
            current += n
            seenNumber = true
        } else {
            return nil
        }
    }
    guard seenNumber else { return nil }
    return Double(total + current)
}

/// Finds the total duration in free text, SUMMING every "<number> <unit>"
/// segment so compounds like "1 hour 30 minutes" yield 5400 (not 3600).
/// Numeric forms use the UPPER bound for ranges ("12-15 minutes" -> 15 min),
/// matching `parseTimers`. Returns nil when no duration is found or the
/// total falls outside 1...43200s (so "0 minutes" and "13 hours" stay
/// `.unknown`).
private func voiceTimerSeconds(in text: String) -> Int? {
    let pattern = #"(\d+(?:\.\d+)?)\s*(?:(?:[-–]|to)\s*(\d+(?:\.\d+)?))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#
    var total = 0
    var found = false
    // Remainder for the word scan: digit "<number> <unit>" spans are blanked
    // so mixed compounds ("1 hour thirty minutes") count both halves once.
    var remainder = text
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        if !matches.isEmpty {
            let ns = text as NSString
            var stripped = text
            for m in matches {
                let secondRange = m.range(at: 2)
                let numStr = secondRange.location != NSNotFound
                    ? ns.substring(with: secondRange)
                    : ns.substring(with: m.range(at: 1))
                let unit = ns.substring(with: m.range(at: 3)).lowercased()
                guard let num = Double(numStr),
                      let part = voiceSeconds(num: num, unit: unit) else { return nil }
                total += part
                found = true
                if let r = Range(m.range, in: stripped) {
                    stripped.replaceSubrange(r, with: String(repeating: " ", count: m.range.length))
                }
            }
            remainder = stripped
        }
    }
    // Number-word forms ("ten minutes", "an hour", "twenty five seconds").
    // Every "<number words> <unit>" segment contributes to the total so
    // "one hour thirty minutes" sums instead of truncating. Runs on the
    // post-digit remainder so mixed compounds count both halves once.
    let hourWords: Set<String> = ["hour", "hours", "hr", "hrs"]
    let minuteWords: Set<String> = ["minute", "minutes", "min", "mins"]
    let secondWords: Set<String> = ["second", "seconds", "sec", "secs"]
    let tokens = remainder.split(separator: " ").map(String.init)
    for (i, token) in tokens.enumerated() {
        let isUnit = hourWords.contains(token)
            || minuteWords.contains(token)
            || secondWords.contains(token)
        guard isUnit else { continue }
        // Wide enough for "two thousand three hundred (minutes)"; the
        // longest trailing slice is tried first so a full valid phrase
        // (e.g. "one hundred") never degrades to a partial ("one" -> 1).
        let start = max(0, i - 6)
        let window = Array(tokens[start..<i])
        // Try the longest trailing slice first ("twenty five"), then shorter.
        var matched: Int?
        for length in stride(from: window.count, through: 1, by: -1) {
            let slice = Array(window.suffix(length))
            if let num = voiceCompoundWordNumber(slice),
               let part = voiceSeconds(num: num, unit: token) {
                matched = part
                break
            }
        }
        // A unit with no parseable number ("minutes" alone) contributes
        // nothing; a number word shared with an earlier unit (e.g. "ten" in
        // "ten minutes thirty seconds") fails the longer slices and falls
        // back to its own trailing number ("thirty").
        if let part = matched { total += part; found = true }
    }
    guard found, total >= 1, total <= 43200 else { return nil }
    return total
}

// MARK: - Parser

/// Parses one standalone voice utterance into a `VoiceCommand`.
/// Mid-sentence input ("please tell me the next step") stays `.unknown` —
/// the caller gates on standalone utterances.
public func parseVoiceCommand(_ transcript: String) -> VoiceCommand {
    let (text, hadWakeWord) = stripVoiceWakeWord(normalizeVoiceText(transcript))
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
    case "double the recipe", "double recipe", "double the scale", "double scale",
          "double":
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

    // Ambiguous utterances: ONLY with the wake-word prefix.
    if hadWakeWord {
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

/// Validates a parsed `.goToStep` request against the recipe length.
/// `VoiceCommand.lastStep` (-1) maps to `stepCount`; any other request must
/// fall in 1...stepCount. Returns nil when out of range (the manager lane
/// uses nil to give an honest "that step doesn't exist" reply instead of
/// clamping). Pure — `parseVoiceCommand` intentionally stays step-count
/// agnostic and carries the requested Int as-is.
public func validatedStep(requested: Int, stepCount: Int) -> Int? {
    guard stepCount > 0 else { return nil }
    if requested == VoiceCommand.lastStep { return stepCount }
    guard (1...stepCount).contains(requested) else { return nil }
    return requested
}

private func parseVoiceTimer(_ text: String) -> VoiceCommand? {
    let prefixes = ["start a timer", "start the timer", "start timer",
                    "set a timer", "set the timer", "set timer"]
    for prefix in prefixes where text == prefix || text.hasPrefix(prefix + " ") {
        var remainder = text == prefix ? "" : String(text.dropFirst(prefix.count + 1))
        if remainder.hasPrefix("for ") { remainder = String(remainder.dropFirst("for ".count)) }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return .startTimer(seconds: nil, label: nil) }
        guard let seconds = voiceTimerSeconds(in: remainder) else { return nil }
        return .startTimer(seconds: seconds, label: nil)
    }

    // Paprika parity: "set a 10 minute timer" / "start 5 minute timers".
    for verb in ["start", "set"] {
        guard text == verb || text.hasPrefix(verb + " ") else { continue }
        var rest = text == verb ? "" : String(text.dropFirst(verb.count + 1))
        if rest.hasPrefix("a ") { rest = String(rest.dropFirst(2)) }
        if rest.hasPrefix("the ") { rest = String(rest.dropFirst(4)) }
        if rest == "timer" || rest == "timers" { return .startTimer(seconds: nil, label: nil) }
        let durationPart: String
        if rest.hasSuffix(" timers") {
            durationPart = String(rest.dropLast(" timers".count))
        } else if rest.hasSuffix(" timer") {
            durationPart = String(rest.dropLast(" timer".count))
        } else {
            continue
        }
        var duration = durationPart.trimmingCharacters(in: .whitespaces)
        if duration.hasPrefix("for ") { duration = String(duration.dropFirst(4)) }
        duration = duration.trimmingCharacters(in: .whitespaces)
        guard !duration.isEmpty, let seconds = voiceTimerSeconds(in: duration) else { continue }
        return .startTimer(seconds: seconds, label: nil)
    }
    return nil
}

private func parseVoiceIngredientAmount(_ text: String) -> VoiceCommand? {
    guard text.hasPrefix("how much ") else { return nil }
    // Longer auxiliaries first so "do i need" wins over the bare "i need".
    let suffixes = ["do i need", "do we need", "will i need", "i need", "we need"]
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

// MARK: - Stable-partial eligibility

/// Whether a parsed command may execute via the client-side stable-partial
/// fallback (see `StablePartialFirer` / `VoiceCookManager`). Unknown
/// partials never fire (they would spam "Sorry…" mid-utterance). Prefix
/// hazards are excluded even when they parse known:
///   - `.stopSpeaking` (bare "stop" is a prefix of "stop cooking"),
///   - all `.startTimer` (bare "start/set timer" needs a real final; numeric
///     durations like "step 1" vs "step 10" shift under more speech),
///   - all `.goToStep` (numeric-prefix hazard: "step 1" vs "step 10").
/// Everything else (next/previous/repeat/startOver/readIngredients/scale/
/// amount/cross/uncross/addToList/stopCooking) may stable-fire once its FULL
/// current text parses known and stays unchanged for the stability window.
public func isStablePartialEligible(_ cmd: VoiceCommand) -> Bool {
    switch cmd {
    case .unknown, .stopSpeaking, .startTimer, .goToStep:
        return false
    default:
        return true
    }
}

// MARK: - Stable partial firer (client-side finals)

/// Client-side stability fallback for devices where Apple endpointing never
/// delivers `isFinal=true` (confirmed device evidence: partials arrive,
/// finals never do). When a partial parses to a KNOWN, stable-eligible
/// command (see `isStablePartialEligible`) and stays unchanged for `delay`
/// seconds, the pending text fires through the manager's final-delivery
/// path — a redundant path alongside real finals, which remain authoritative.
///
/// Timing is injectable: production passes a DispatchQueue.main scheduler;
/// tests pass a fake that captures work and fires it manually.
public final class StablePartialFirer {
    /// Stability window: partial must be unchanged this long to fire.
    public static let defaultDelay: TimeInterval = 1.4
    private let delay: TimeInterval
    private let isEligible: (String) -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let onFire: (String) -> Void
    private var pendingText: String?
    private var cancelWork: (() -> Void)?

    public init(delay: TimeInterval = StablePartialFirer.defaultDelay,
                isEligible: @escaping (String) -> Bool = { isStablePartialEligible(parseVoiceCommand($0)) },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> (() -> Void),
                onFire: @escaping (String) -> Void) {
        self.delay = delay
        self.isEligible = isEligible
        self.schedule = schedule
        self.onFire = onFire
    }

    /// Main-queue scheduler for production use.
    public static func mainQueueSchedule(delay: TimeInterval, work: @escaping () -> Void) -> (() -> Void) {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    /// Latest pending text (nil when idle). Exposed for tests.
    public var pending: String? { pendingText }

    /// Observe one partial. Unknown/ineligible partials NEVER arm the timer;
    /// a changed eligible partial cancels and replaces the pending timer;
    /// an identical repeat keeps the existing timer so speech cadence
    /// doesn't restart it.
    public func notePartial(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isEligible(trimmed) else {
            cancelPending()
            return
        }
        if pendingText == trimmed { return }
        cancelWork?()
        pendingText = trimmed
        let expected = trimmed
        cancelWork = schedule(delay) { [weak self] in
            guard let self, self.pendingText == expected else { return }
            self.pendingText = nil
            self.cancelWork = nil
            self.onFire(expected)
        }
    }

    public func cancelPending() {
        cancelWork?()
        cancelWork = nil
        pendingText = nil
    }
}

// MARK: - Stable delivery consumption (late-final dedup)

/// Single-use consumption guard for a stable-fired text. A late Apple final
/// for the SAME text arriving before the soft restart dedups instead of
/// double-firing (`shouldDropFinal` consumes the guard); the soft restart
/// clears it so the SAME command works again in the new generation (stale
/// late finals from the old task never reach the manager — the input's
/// generation guard drops them first).
public struct StableConsumeState {
    private var deliveredText: String?

    public init() {}

    public mutating func recordStableDelivery(_ text: String) {
        deliveredText = text
    }

    /// Returns true when this real final must be dropped as a late duplicate
    /// of a just-stable-fired delivery. Consumes the guard (one duplicate
    /// dropped, never a blanket suppression of repeats).
    public mutating func shouldDropFinal(_ text: String) -> Bool {
        guard let delivered = deliveredText, delivered == text else { return false }
        deliveredText = nil
        return true
    }

    /// New generation (post-stable soft restart): the same word is allowed
    /// again.
    public mutating func resetForNewGeneration() {
        deliveredText = nil
    }
}
