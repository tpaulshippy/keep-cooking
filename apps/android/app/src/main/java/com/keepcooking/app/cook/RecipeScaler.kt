package com.keepcooking.app.cook

import kotlin.math.ceil
import kotlin.math.floor

/**
 * Recipe scaling — port of apps/ios/Features/Cook/RecipeScaler.swift.
 * Pure logic, no Android dependencies.
 *
 * Matches Lane 1 POST /recipes/:id/scale { servings: 0.25..100 }.
 * Factor is clamped to 0.25x–4x; quantities render as fraction-rounded
 * display strings (nearest 1/4, unicode fractions).
 */

/** Scaling factor from base servings to target servings, clamped to 0.25x–4x. */
fun scaleFactor(baseServings: Double, targetServings: Double): Double {
    if (baseServings <= 0 || targetServings <= 0) return 1.0
    val raw = targetServings / baseServings
    return raw.coerceIn(0.25, 4.0)
}

/** Scaled quantity for one ingredient (null stays null — "to taste" etc.). */
fun scaledQuantity(quantity: Double?, factor: Double): Double? {
    if (quantity == null) return null
    return quantity * factor
}

/**
 * Rounds a value to the nearest quarter (0.25 steps), halves away from
 * zero — parity with iOS `(value * 4).rounded()` (`.toNearestOrAwayFromZero`).
 * kotlin.math.round is banker's (half to even): 0.125*4 = 0.5 would round to
 * 0 ("0") instead of 1 ("¼"). Explicit half-away keeps 1/8 -> 1/4 etc.
 */
fun roundToQuarter(value: Double): Double {
    val q = value * 4
    return if (q >= 0) floor(q + 0.5) / 4 else ceil(q - 0.5) / 4
}

private val fractionGlyphs: List<Pair<Double, String>> = listOf(
    0.125 to "⅛", 0.25 to "¼", 0.333 to "⅓", 0.375 to "⅜",
    0.5 to "½", 0.625 to "⅝", 0.666 to "⅔", 0.75 to "¾", 0.875 to "⅞",
)

/**
 * Formats a quantity as a fraction-rounded display string, e.g. 1.5 -> "1½".
 * Whole numbers render without fractions; values < 1 render glyph-only.
 */
fun fractionDisplayString(value: Double): String {
    val rounded = roundToQuarter(value)
    val whole = rounded.toInt()
    val frac = rounded - whole
    var best: String? = null
    var bestDist = Double.MAX_VALUE
    for ((glyphValue, glyph) in fractionGlyphs) {
        val d = kotlin.math.abs(glyphValue - frac)
        if (d < bestDist) {
            bestDist = d
            best = glyph
        }
    }
    if (frac < 0.06) return "$whole" // effectively whole
    if (best == null || bestDist >= 0.13) {
        // Fall back to a 2-decimal string rather than a wrong fraction.
        return "%.2f".format(rounded)
    }
    if (whole == 0) return best
    return "$whole$best"
}

/**
 * Full scaled display line for one ingredient, e.g. "1½ cups flour".
 * @param name ingredient name; quantity base quantity (null = unmeasured);
 *   unit base unit ("" when none); factor clamped scale factor.
 */
fun scaledDisplay(name: String, quantity: Double?, unit: String, factor: Double): String {
    val q = scaledQuantity(quantity, factor) ?: return name
    val qty = fractionDisplayString(q)
    if (unit.isEmpty()) return "$qty $name"
    return "$qty $unit $name"
}
