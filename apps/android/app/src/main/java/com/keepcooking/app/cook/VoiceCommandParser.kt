package com.keepcooking.app.cook

/**
 * Hands-free cook command parser — port of
 * apps/ios/Features/Cook/VoiceCommandParser.swift (pure).
 *
 * Maps one standalone utterance transcript to a [VoiceCommand].
 * Conventions:
 *   - Input is a raw transcript; normalization (lowercase, trim, trailing
 *     period strip) happens inside [parseVoiceCommand].
 *   - A leading "keep cooking" / "hey keep cooking" wake-word prefix is stripped before
 *     matching. Ambiguous utterances ("i'm done", "goodbye", "what was that?",
 *     "come again", "cancel", "halve it", "double it") are ONLY honored when
 *     that prefix was present; bare they parse as [VoiceCommand.Unknown].
 */

sealed interface VoiceCommand {
    data object Next : VoiceCommand
    data object Previous : VoiceCommand
    data object RepeatStep : VoiceCommand
    /** 1-based step number; [LAST_STEP] (-1) means the last step. */
    data class GoToStep(val step: Int) : VoiceCommand
    data object StartOver : VoiceCommand
    data object ReadIngredients : VoiceCommand
    data class IngredientAmount(val name: String) : VoiceCommand
    data class CrossOff(val name: String) : VoiceCommand
    data class Uncross(val name: String) : VoiceCommand
    data object DoubleScale : VoiceCommand
    data object HalveScale : VoiceCommand
    data object ResetScale : VoiceCommand
    data class AddToList(val listName: String?) : VoiceCommand
    data class StartTimer(val seconds: Int?, val label: String?) : VoiceCommand
    data object StopSpeaking : VoiceCommand
    data object StopCooking : VoiceCommand
    data object Unknown : VoiceCommand

    companion object {
        /** Sentinel for [GoToStep] meaning "the last step". */
        const val LAST_STEP: Int = -1
    }
}

/** Lowercases, trims, drops apostrophes, strips trailing sentence punctuation, collapses whitespace. */
fun normalizeVoiceText(raw: String): String {
    var s = raw.lowercase().trim()
    s = s.replace("'", "")
        .replace("’", "")
        .replace("‘", "")
        .replace("`", "")
    while (s.isNotEmpty() && s.last() in listOf('.', '!', '?')) {
        s = s.dropLast(1)
    }
    s = s.trim()
    return s.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
}

/** Ingredient-name normalization: voice normalization plus a leading "the" strip. */
fun voiceNormalizedName(raw: String): String {
    var s = normalizeVoiceText(raw)
    if (s.startsWith("the ")) s = s.drop(4)
    return s
}

/** Strips a leading "keep cooking" / "hey keep cooking" wake-word prefix. Returns remainder + whether prefix was present. */
internal fun stripVoiceWakeWord(text: String): Pair<String, Boolean> {
    for (prefix in listOf("hey keep cooking", "keep cooking")) {
        if (text == prefix) return "" to true
        if (text.startsWith("$prefix ")) return text.drop(prefix.length + 1) to true
        if (text.startsWith("$prefix,")) {
            return text.drop(prefix.length + 1).trim() to true
        }
    }
    return text to false
}

private val voiceOnes: Map<String, Int> = mapOf(
    "zero" to 0, "one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5,
    "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9, "ten" to 10,
    "eleven" to 11, "twelve" to 12, "thirteen" to 13, "fourteen" to 14,
    "fifteen" to 15, "sixteen" to 16, "seventeen" to 17, "eighteen" to 18,
    "nineteen" to 19, "twenty" to 20,
    "first" to 1, "second" to 2, "third" to 3, "fourth" to 4, "fifth" to 5,
    "sixth" to 6, "seventh" to 7, "eighth" to 8, "ninth" to 9, "tenth" to 10,
    "eleventh" to 11, "twelfth" to 12, "thirteenth" to 13, "fourteenth" to 14,
    "fifteenth" to 15, "sixteenth" to 16, "seventeenth" to 17, "eighteenth" to 18,
    "nineteenth" to 19, "twentieth" to 20,
)

private val voiceTens: Map<String, Int> = mapOf(
    "twenty" to 20, "thirty" to 30, "forty" to 40, "fifty" to 50,
    "sixty" to 60, "seventy" to 70, "eighty" to 80, "ninety" to 90,
)

/** Number words one–twenty (plus ordinals and tens compounds up to 99). Null when the token isn't a number. */
fun voiceNumberValue(token: String): Int? {
    val t = token.trim().lowercase()
    if (t.isEmpty()) return null
    t.toIntOrNull()?.let { return it }
    voiceOnes[t]?.let { return it }
    voiceTens[t]?.let { return it }
    val parts = t.split(" ")
    if (parts.size == 2) {
        val tens = voiceTens[parts[0]]
        val ones = voiceOnes[parts[1]]
        if (tens != null && ones != null && ones < 10) return tens + ones
    }
    return null
}

/**
 * Best fuzzy match for a spoken ingredient name against candidate labels.
 * Token-boundary-aware scoring: normalized exact equality outranks exact
 * token overlap, which outranks token-boundary phrase containment.
 * Returns the original (non-normalized) candidate, or null on no match or tie.
 */
fun fuzzyVoiceMatch(query: String, candidates: List<String>): String? {
    val q = voiceNormalizedName(query)
    if (q.isEmpty()) return null
    val qTokens = q.split(" ")
    val qSet = qTokens.toSet()
    var bestKey: Triple<Int, Int, Int>? = null
    var bestCandidate: String? = null
    var bestCount = 0
    for (candidate in candidates) {
        val c = voiceNormalizedName(candidate)
        if (c.isEmpty()) continue
        val cTokens = c.split(" ")
        val key: Triple<Int, Int, Int> = if (c == q) {
            Triple(3, qTokens.size, q.length)
        } else {
            val cSet = cTokens.toSet()
            val overlap = qSet.intersect(cSet)
            if (overlap.isNotEmpty()) {
                Triple(2, overlap.size, overlap.sumOf { it.length })
            } else if (voiceTokenBoundaryContains(c, q) || voiceTokenBoundaryContains(q, c)) {
                val needle = if (c.length > q.length) q else c
                Triple(1, 1, needle.length)
            } else {
                continue
            }
        }
        if (bestKey == null || compareTriple(key, bestKey) > 0) {
            bestKey = key
            bestCandidate = candidate
            bestCount = 1
        } else if (key == bestKey) {
            bestCount += 1
        }
    }
    if (bestCount != 1) return null
    return bestCandidate
}

private fun compareTriple(a: Triple<Int, Int, Int>, b: Triple<Int, Int, Int>): Int {
    if (a.first != b.first) return a.first.compareTo(b.first)
    if (a.second != b.second) return a.second.compareTo(b.second)
    return a.third.compareTo(b.third)
}

/** Token-boundary containment: [needle] appears in [haystack] as whole phrase tokens. */
private fun voiceTokenBoundaryContains(haystack: String, needle: String): Boolean {
    if (haystack == needle) return true
    fun norm(s: String) = s.replace("-", " ").replace("/", " ")
    val h = norm(haystack)
    val n = norm(needle)
    if (h == n) return true
    return h.startsWith("$n ") || h.endsWith(" $n") || h.contains(" $n ")
}

private fun voiceSeconds(num: Double, unit: String): Int? {
    val multiplier: Double = when {
        unit.startsWith("h") -> 3600.0
        unit.startsWith("m") -> 60.0
        unit.startsWith("s") -> 1.0
        else -> return null
    }
    if (!num.isFinite()) return null
    val raw = kotlin.math.round(num * multiplier)
    if (!raw.isFinite() || raw < 1 || raw > 43200) return null
    return raw.toInt()
}

private fun voiceCompoundWordNumber(words: List<String>): Double? {
    if (words.isEmpty()) return null
    if (words.size == 1) {
        val w = words[0]
        if (w == "a" || w == "an") return 1.0
        w.toIntOrNull()?.let { return it.toDouble() }
        voiceNumberValue(w)?.let { return it.toDouble() }
        return null
    }
    var total = 0
    var current = 0
    var seenNumber = false
    for (w in words) {
        when {
            w == "and" -> Unit
            w == "a" || w == "an" -> { current += 1; seenNumber = true }
            voiceOnes[w] != null -> { current += voiceOnes[w]!!; seenNumber = true }
            voiceTens[w] != null -> { current += voiceTens[w]!!; seenNumber = true }
            w == "hundred" || w == "hundreds" -> {
                if (current <= 0) return null
                current *= 100
                seenNumber = true
            }
            w == "thousand" || w == "thousands" -> {
                if (current <= 0) return null
                total += current * 1000
                current = 0
                seenNumber = true
            }
            w.toIntOrNull() != null -> { current += w.toInt(); seenNumber = true }
            else -> return null
        }
    }
    if (!seenNumber) return null
    return (total + current).toDouble()
}

/** Sums every duration segment in free text ("1 hour 30 minutes" -> 5400). Numeric ranges use the UPPER bound. */
private fun voiceTimerSeconds(text: String): Int? {
    // Double accumulator: huge spoken durations (e.g. "9999999999 hours")
    // would wrap a Long past the 1..43200 range check; Double holds them until
    // the same range test below rejects them.
    var total = 0.0
    var found = false
    val numeric = Regex(
        """(\d+(?:\.\d+)?)\s*(?:(?:[-–]|to)\s*(\d+(?:\.\d+)?))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b""",
        RegexOption.IGNORE_CASE,
    )
    val consumed = numeric.findAll(text).toList()
    for (m in consumed) {
        val secondStr = m.groupValues[2]
        val numStr = if (secondStr.isNotEmpty()) secondStr else m.groupValues[1]
        val unit = m.groupValues[3].lowercase()
        voiceSecondsRaw(numStr.toDoubleOrNull() ?: continue, unit)?.let { total += it.toDouble(); found = true }
    }
    val consumedRanges = consumed.map { it.range }
    // Char spans of whitespace-separated tokens, to avoid double-counting numeric hits.
    val spans = mutableListOf<IntRange>()
    var i = 0
    while (i < text.length) {
        while (i < text.length && text[i].isWhitespace()) i++
        if (i >= text.length) break
        val start = i
        while (i < text.length && !text[i].isWhitespace()) i++
        spans.add(start until i)
    }
    val tokens = spans.map { text.substring(it.first, it.last + 1) }
    fun isConsumed(span: IntRange) = consumedRanges.any { it.first <= span.last && span.first <= it.last }
    val hourWords = setOf("hour", "hours", "hr", "hrs")
    val minuteWords = setOf("minute", "minutes", "min", "mins")
    val secondWords = setOf("second", "seconds", "sec", "secs")
    for ((idx, token) in tokens.withIndex()) {
        if (token !in hourWords && token !in minuteWords && token !in secondWords) continue
        if (isConsumed(spans[idx])) continue
        val window = mutableListOf<String>()
        var j = idx - 1
        while (j >= 0 && window.size < 6) {
            if (!isConsumed(spans[j])) window.add(0, tokens[j])
            j--
        }
        for (length in window.size downTo 1) {
            val num = voiceCompoundWordNumber(window.takeLast(length)) ?: continue
            voiceSecondsRaw(num, token)?.let { total += it.toDouble(); found = true }
            break
        }
    }
    if (!found || total < 1 || total > 43200) return null
    return total.toInt()
}

private fun voiceSecondsRaw(num: Double, unit: String): Long? {
    val multiplier: Double = when {
        unit.startsWith("h") -> 3600.0
        unit.startsWith("m") -> 60.0
        unit.startsWith("s") -> 1.0
        else -> return null
    }
    if (!num.isFinite()) return null
    return kotlin.math.round(num * multiplier).toLong()
}

/**
 * Parses one standalone voice utterance into a [VoiceCommand].
 * Mid-sentence input ("please tell me the next step") stays [VoiceCommand.Unknown].
 */
fun parseVoiceCommand(transcript: String): VoiceCommand {
    val (text, hadWakeWord) = stripVoiceWakeWord(normalizeVoiceText(transcript))
    if (text.isEmpty()) return VoiceCommand.Unknown

    when (text) {
        "next", "next step", "go next", "go forward", "move on" -> return VoiceCommand.Next
        "previous", "previous step", "go back", "back", "last one" -> return VoiceCommand.Previous
        "repeat", "repeat step", "repeat that", "say that again",
        "read that again", "read it again", "read this step" -> return VoiceCommand.RepeatStep
        "start over", "start from the beginning", "restart",
        "restart the recipe", "start from the start" -> return VoiceCommand.StartOver
        "read ingredients", "read the ingredients", "list ingredients",
        "list the ingredients", "what are the ingredients" -> return VoiceCommand.ReadIngredients
        "double the recipe", "double recipe", "double the scale", "double scale" -> return VoiceCommand.DoubleScale
        "halve the recipe", "halve recipe", "halve the scale", "halve scale" -> return VoiceCommand.HalveScale
        "reset the recipe", "reset recipe", "reset the scale", "reset scale",
        "reset servings", "reset the servings" -> return VoiceCommand.ResetScale
        "stop", "stop speaking", "stop reading", "stop talking",
        "be quiet", "quiet" -> return VoiceCommand.StopSpeaking
        "stop cooking", "exit cooking", "leave cook mode",
        "finish cooking", "quit cooking", "end cooking" -> return VoiceCommand.StopCooking
        "start the timer", "start timer", "start a timer",
        "set the timer", "set timer", "set a timer" -> return VoiceCommand.StartTimer(seconds = null, label = null)
    }

    parseVoiceGoToStep(text)?.let { return it }
    parseVoiceTimer(text)?.let { return it }
    parseVoiceIngredientAmount(text)?.let { return it }
    parseVoiceCrossOff(text)?.let { return it }
    parseVoiceUncross(text)?.let { return it }
    parseVoiceAddToList(text)?.let { return it }

    // Ambiguous utterances: ONLY with the wake-word prefix.
    if (hadWakeWord) {
        when (text) {
            "im done" -> return VoiceCommand.Next
            "goodbye", "cancel" -> return VoiceCommand.StopCooking
            "what was that" -> return VoiceCommand.RepeatStep
            "come again" -> return VoiceCommand.RepeatStep
            "halve it" -> return VoiceCommand.HalveScale
            "double it" -> return VoiceCommand.DoubleScale
        }
    }
    return VoiceCommand.Unknown
}

private fun parseVoiceGoToStep(text: String): VoiceCommand? {
    if (!text.startsWith("go to ")) return null
    var rest = text.drop("go to ".length)
    if (rest.startsWith("the ")) rest = rest.drop("the ".length)
    if (rest == "last" || rest == "last step") return VoiceCommand.GoToStep(VoiceCommand.LAST_STEP)
    if (!rest.startsWith("step ")) return null
    val token = rest.drop("step ".length).trim()
    if (token == "last") return VoiceCommand.GoToStep(VoiceCommand.LAST_STEP)
    val n = voiceNumberValue(token) ?: return null
    if (n <= 0) return null
    return VoiceCommand.GoToStep(n)
}

/**
 * Validates a parsed [VoiceCommand.GoToStep] request against the recipe length.
 * [VoiceCommand.LAST_STEP] (-1) maps to [stepCount]; any other request must
 * fall in 1..stepCount. Returns null when out of range. Pure — [parseVoiceCommand]
 * intentionally stays step-count agnostic and carries the requested Int as-is.
 */
fun validatedStep(requested: Int, stepCount: Int): Int? {
    if (stepCount <= 0) return null
    if (requested == VoiceCommand.LAST_STEP) return stepCount
    if (requested !in 1..stepCount) return null
    return requested
}

private fun parseVoiceTimer(text: String): VoiceCommand? {
    val prefixes = listOf("start a timer", "start the timer", "start timer", "set a timer", "set the timer", "set timer")
    for (prefix in prefixes) {
        if (text == prefix || text.startsWith("$prefix ")) {
            var rest = if (text == prefix) "" else text.drop(prefix.length + 1)
            if (rest.startsWith("for ")) rest = rest.drop("for ".length)
            rest = rest.trim()
            if (rest.isEmpty()) return VoiceCommand.StartTimer(seconds = null, label = null)
            val seconds = voiceTimerSeconds(rest) ?: return null
            return VoiceCommand.StartTimer(seconds = seconds, label = null)
        }
    }
    // Paprika parity: "set a 10 minute timer" / "start 5 minute timers".
    for (verb in listOf("start", "set")) {
        if (text != verb && !text.startsWith("$verb ")) continue
        var rest = if (text == verb) "" else text.drop(verb.length + 1)
        var unstripped: String? = null
        for (article in listOf("a ", "an ", "the ")) {
            if (rest.startsWith(article)) {
                unstripped = rest
                rest = rest.drop(article.length)
                break
            }
        }
        if (rest == "timer") return VoiceCommand.StartTimer(seconds = null, label = null)
        val seconds = parsePaprikaTimerBody(rest)
            ?: unstripped?.let { parsePaprikaTimerBody(it) } ?: continue
        return VoiceCommand.StartTimer(seconds = seconds, label = null)
    }
    return null
}

/**
 * Parses the body of a Paprika-style timer command ("10 minute" from
 * "set a 10 minute timer"). Null when there is no "<duration> timer" shape
 * or the duration is unparseable. The caller retries with the article
 * intact since "a"/"an" can be the quantity ("a minute" = 60s).
 */
private fun parsePaprikaTimerBody(rest: String): Int? {
    val durationPart = when {
        rest.endsWith(" timers") -> rest.dropLast(" timers".length)
        rest.endsWith(" timer") -> rest.dropLast(" timer".length)
        else -> return null
    }
    var duration = durationPart.trim()
    if (duration.startsWith("for ")) duration = duration.drop(4)
    duration = duration.trim()
    if (duration.isEmpty()) return null
    return voiceTimerSeconds(duration)
}

private fun parseVoiceIngredientAmount(text: String): VoiceCommand? {
    if (!text.startsWith("how much ")) return null
    // Longer auxiliaries first so "do i need" wins over the bare "i need".
    val suffixes = listOf("do i need", "do we need", "will i need", "i need", "we need")
    var middle: String? = null
    for (suffix in suffixes) {
        if (text.endsWith(suffix)) {
            middle = text.drop("how much ".length).dropLast(suffix.length)
            break
        }
    }
    var name = middle?.trim() ?: return null
    if (name.isEmpty()) return null
    if (name.startsWith("of ")) name = name.drop("of ".length)
    name = voiceNormalizedName(name)
    if (name.isEmpty()) return null
    return VoiceCommand.IngredientAmount(name = name)
}

private fun parseVoiceCrossOff(text: String): VoiceCommand? {
    for (prefix in listOf("cross off ", "check off ")) {
        if (text.startsWith(prefix)) {
            val name = voiceNormalizedName(text.drop(prefix.length))
            if (name.isEmpty()) return null
            return VoiceCommand.CrossOff(name = name)
        }
    }
    return null
}

private fun parseVoiceUncross(text: String): VoiceCommand? {
    for (prefix in listOf("uncross off ", "uncheck off ", "uncross ", "uncheck ")) {
        if (text.startsWith(prefix)) {
            val name = voiceNormalizedName(text.drop(prefix.length))
            if (name.isEmpty()) return null
            return VoiceCommand.Uncross(name = name)
        }
    }
    return null
}

private fun parseVoiceAddToList(text: String): VoiceCommand? {
    var remainder: String? = null
    for (prefix in listOf("add the ingredients to my ", "add ingredients to my ")) {
        if (text.startsWith(prefix)) {
            remainder = text.drop(prefix.length)
            break
        }
    }
    val rest = remainder ?: return null
    if (rest == "list") return VoiceCommand.AddToList(listName = null)
    if (!rest.endsWith(" list")) return null
    val name = rest.dropLast(" list".length).trim()
    if (name.isEmpty()) return null
    return VoiceCommand.AddToList(listName = name)
}
