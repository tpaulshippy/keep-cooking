package com.keepcooking.app.cook

/**
 * Time-string → multi-timer parser — port of
 * apps/ios/Features/Cook/StepTimerParser.swift (pure).
 * Turns free-text step strings into zero or more timers, e.g.
 *   "bake 12-15 min, rest 1 hr" -> [12..15min upper=15min "bake", 1hr "rest"]
 * Rules:
 *   - Ranges use the UPPER bound ("12-15 min" -> 15 min).
 *   - Units: hr/hrs/hour(s) = 3600s, min/mins/minute(s) = 60s, sec(s)/second(s) = 1s.
 *   - The label is the closest preceding verb-ish word run before the duration
 *     (up to 2 words), falling back to the whole step prefix trimmed to 24 chars.
 *   - Returns emptyList() when nothing parses.
 */

/** One parsed timer: fire after [seconds] with a human [label]. */
data class ParsedTimer(val seconds: Int, val label: String)

private val timerPattern =
    Regex("""(\d+(?:\.\d+)?)\s*(?:[-–]\s*(\d+(?:\.\d+)?))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b""", RegexOption.IGNORE_CASE)

/** Parses all durations out of a step text string. */
fun parseTimers(from: String): List<ParsedTimer> {
    val out = mutableListOf<ParsedTimer>()
    for (m in timerPattern.findAll(from)) {
        val firstStr = m.groupValues[1]
        val secondStr = m.groupValues[2]
        val numStr = if (secondStr.isNotEmpty()) secondStr else firstStr
        val unitStr = m.groupValues[3].lowercase()
        val num = numStr.toDoubleOrNull() ?: continue
        val multiplier: Double = when {
            unitStr.startsWith("h") -> 3600.0
            unitStr.startsWith("min") -> 60.0
            unitStr.startsWith("sec") -> 1.0
            unitStr == "m" -> 60.0 // "m" shorthand (unreachable via pattern today; kept for parity)
            unitStr == "s" -> 1.0
            unitStr.startsWith("m") -> 60.0 // "m" shorthand
            else -> continue
        }
        val seconds = kotlin.math.round(num * multiplier).toInt()
        if (seconds <= 0) continue
        out.add(ParsedTimer(seconds = seconds, label = labelBefore(matchStart = m.range.first, text = from)))
    }
    return out
}

/** Best-effort label: last ≤2 words before the duration match. */
private fun labelBefore(matchStart: Int, text: String): String {
    val prefix = text.substring(0, matchStart.coerceIn(0, text.length))
    val words = prefix.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
    val tail = words.takeLast(2).joinToString(" ")
    if (tail.isNotEmpty()) return tail
    // Fallback: trimmed prefix, capped at 24 chars.
    val trimmed = prefix.trim()
    if (trimmed.isEmpty()) return "Timer"
    return trimmed.takeLast(24).trim()
}
