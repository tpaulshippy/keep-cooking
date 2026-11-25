package com.keepcooking.app.cook

/**
 * Time-string → multi-timer parser — port of
 * apps/ios/Features/Cook/StepTimerParser.swift (pure).
 * Turns free-text step strings into zero or more timers, e.g.
 *   "bake 12-15 min, rest 1 hr" -> [12..15min upper=15min "bake", 1hr "rest"]
 * Rules:
 *   - Ranges use the UPPER bound ("12-15 min" -> 15 min).
 *   - Bare fractions never match ("1/2 hour" -> no timers: the number must
 *     not be preceded by a digit or slash).
 *   - Adjacent unit segments sum ("1 hour 30 minutes" -> one 90-min timer).
 *   - Units: hr/hrs/hour(s) = 3600s, min/mins/minute(s) = 60s, sec(s)/second(s) = 1s.
 *   - The label is the closest preceding verb-ish word run before the duration
 *     (up to 2 words), starting AFTER the previous duration match so a second
 *     timer's label never leaks words from the first ("bake 12-15 min, rest
 *     1 hr" -> "bake", "rest"), falling back to the whole step prefix trimmed
 *     to 24 chars.
 *   - Returns emptyList() when nothing parses.
 */

/** One parsed timer: fire after [seconds] with a human [label]. */
data class ParsedTimer(val seconds: Int, val label: String)

private val timerPattern =
    // (?<![\d/]): a duration number must not start inside a larger number or a
    // fraction ("1/2 hour" matches neither "1" — blocked by what follows — nor
    // "2", which is preceded by "/").
    Regex("""(?<![\d/])(\d+(?:\.\d+)?)\s*(?:[-–]\s*(\d+(?:\.\d+)?))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b""", RegexOption.IGNORE_CASE)

/** Gap text that joins two durations into one compound timer ("1 hour and 30 minutes"). */
private fun isCompoundGap(gap: String): Boolean {
    val t = gap.trim().lowercase()
    return t.isEmpty() || t == "and" || t == "+" || t == "&"
}

/**
 * Parses all durations out of a step text string.
 * Adjacent segments (separated only by whitespace, "and", "+" or "&") sum into a single
 * timer; anything else (commas, words) starts a new timer whose label window
 * begins after the previous match.
 */
fun parseTimers(from: String): List<ParsedTimer> {
    val out = mutableListOf<ParsedTimer>()
    var prevEnd = 0
    var prevAccepted = false
    for (m in timerPattern.findAll(from)) {
        val firstStr = m.groupValues[1]
        val secondStr = m.groupValues[2]
        val numStr = if (secondStr.isNotEmpty()) secondStr else firstStr
        val unitStr = m.groupValues[3].lowercase()
        val num = numStr.toDoubleOrNull()
        val multiplier: Double = when {
            unitStr.startsWith("h") -> 3600.0
            unitStr.startsWith("min") -> 60.0
            unitStr.startsWith("sec") -> 1.0
            unitStr == "m" -> 60.0 // "m" shorthand (unreachable via pattern today; kept for parity)
            unitStr == "s" -> 1.0
            unitStr.startsWith("m") -> 60.0 // "m" shorthand
            else -> null
        } ?: continue
        val start = m.range.first.coerceIn(0, from.length)
        val end = (m.range.last + 1).coerceIn(0, from.length)
        val gap = from.substring(prevEnd.coerceIn(0, from.length), start)
        val labelBoundary = prevEnd
        prevEnd = end
        // A skipped (zero/unparseable) match still advances the label boundary
        // so later labels stay tight, but it must NOT coalesce: only merge
        // into the previous timer when the immediately preceding duration was
        // accepted, otherwise later seconds join an unrelated earlier timer.
        if (num == null || !num.isFinite()) {
            prevAccepted = false
            continue
        }
        val seconds = kotlin.math.round(num * multiplier).toInt()
        if (seconds <= 0) {
            prevAccepted = false
            continue
        }
        if (out.isNotEmpty() && prevAccepted && isCompoundGap(gap)) {
            val last = out.removeAt(out.lastIndex)
            out.add(last.copy(seconds = last.seconds + seconds))
        } else {
            out.add(ParsedTimer(seconds = seconds, label = labelBefore(matchStart = start, text = from, boundary = labelBoundary)))
        }
        prevAccepted = true
    }
    return out
}

/** Best-effort label: last ≤2 words between [boundary] and the duration match. */
private fun labelBefore(matchStart: Int, text: String, boundary: Int = 0): String {
    val from = boundary.coerceIn(0, text.length)
    val prefix = text.substring(from, matchStart.coerceIn(from, text.length))
    val words = prefix.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
    val tail = words.takeLast(2).joinToString(" ")
    if (tail.isNotEmpty()) return tail
    // Fallback: trimmed prefix, capped at 24 chars.
    val trimmed = prefix.trim()
    if (trimmed.isEmpty()) return "Timer"
    return trimmed.takeLast(24).trim()
}
