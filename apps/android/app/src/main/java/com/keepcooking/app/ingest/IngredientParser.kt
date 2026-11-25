package com.keepcooking.app.ingest

/**
 * Single-line ingredient parser — port of iOS IngredientParser.swift.
 * Pure Kotlin; handles unicode fractions, ASCII fractions, mixed numbers,
 * ranges, decimals, and unit aliases.
 */
data class ParsedIngredient(
    val quantity: Double?,
    /** Original text e.g. "2-3" for ranges. */
    val quantityText: String? = null,
    val unit: String = "",
    val name: String = "",
    val display: String = "",
)

object IngredientParser {
    val unicodeFractions: Map<Char, Double> = mapOf(
        '½' to 0.5, '⅓' to 1.0 / 3.0, '⅔' to 2.0 / 3.0, '¼' to 0.25, '¾' to 0.75,
        '⅛' to 0.125, '⅜' to 0.375, '⅝' to 0.625, '⅞' to 0.875,
        '⅕' to 0.2, '⅖' to 0.4, '⅗' to 0.6, '⅘' to 0.8, '⅙' to 1.0 / 6.0, '⅚' to 5.0 / 6.0,
    )

    /** Canonical unit map: alias (lowercased, punctuation stripped) → canonical. */
    val unitAliases: Map<String, String> = mapOf(
        "tbsp" to "tbsp", "tbs" to "tbsp", "tablespoon" to "tbsp", "tablespoons" to "tbsp",
        "tsp" to "tsp", "teaspoon" to "tsp", "teaspoons" to "tsp",
        "cup" to "cup", "cups" to "cup", "c" to "cup",
        "g" to "g", "gram" to "g", "grams" to "g", "gramme" to "g",
        "kg" to "kg", "ml" to "ml", "milliliter" to "ml", "millilitre" to "ml",
        "l" to "l", "liter" to "l", "litre" to "l",
        "oz" to "oz", "ounce" to "oz", "ounces" to "oz",
        "lb" to "lb", "lbs" to "lb", "pound" to "lb", "pounds" to "lb",
        "clove" to "clove", "cloves" to "clove",
        "can" to "can", "cans" to "can", "pack" to "pack", "packs" to "pack",
        "slice" to "slice", "slices" to "slice", "pinch" to "pinch", "dash" to "dash",
    )

    /** Parse one ingredient line. Never returns null — unparseable lines keep the whole line as name. */
    fun parse(line: String): ParsedIngredient {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return ParsedIngredient(null, null, "", "", trimmed)
        val tokens = trimmed.split(" ").filter { it.isNotEmpty() }.toMutableList()
        if (tokens.isEmpty()) return ParsedIngredient(null, null, "", trimmed, trimmed)

        var quantity: Double? = null
        var quantityText: String? = null
        var consumed = 0

        // Mixed number "<int> <frac|unicode>"
        if (tokens.size >= 2 && tokens[0].toIntOrNull() != null && fractionValue(tokens[1]) != null) {
            quantity = tokens[0].toInt() + fractionValue(tokens[1])!!
            quantityText = "${tokens[0]} ${tokens[1]}"
            consumed = 2
        } else {
            val range = rangeValue(tokens[0])
            if (range != null) {
                quantity = range.midpoint
                quantityText = tokens[0]
                consumed = 1
            } else {
                val v = fractionValue(tokens[0]) ?: doubleValue(tokens[0])
                if (v != null) {
                    quantity = v
                    quantityText = tokens[0]
                    consumed = 1
                }
            }
        }
        // Unicode attached to digit e.g. "1½"
        if (quantity == null) {
            val attached = attachedUnicodeValue(tokens[0])
            if (attached != null) {
                quantity = attached.value
                quantityText = tokens[0]
                consumed = 1
            }
        }

        repeat(minOf(consumed, tokens.size)) { tokens.removeAt(0) }

        // Unit: next token if it matches a known alias.
        var unit = ""
        if (tokens.isNotEmpty() && canonicalUnit(tokens[0]) != null) {
            unit = canonicalUnit(tokens[0])!!
            tokens.removeAt(0)
        }

        var name = tokens.joinToString(" ")
        if (quantity == null && unit.isEmpty()) name = trimmed
        name = name.trim()

        val display = buildDisplay(quantity, quantityText, unit, name, trimmed)
        return ParsedIngredient(quantity, quantityText, unit, name, display)
    }

    /** Parse many lines (caption / OCR block), skipping blanks. */
    fun parseLines(text: String): List<ParsedIngredient> =
        text.split("\n").map { it.trim() }.filter { it.isNotEmpty() }.map { parse(it) }

    fun fractionValue(token: String): Double? {
        val t = token.trim()
        if (t.length == 1) {
            unicodeFractions[t[0]]?.let { return it }
            when (t[0].code) {
                0xBC -> return 0.25
                0xBD -> return 0.5
                0xBE -> return 0.75
            }
        }
        if (t.contains("/")) {
            val parts = t.split("/")
            if (parts.size == 2) {
                val n = parts[0].toDoubleOrNull()
                val d = parts[1].toDoubleOrNull()
                if (n != null && d != null && d != 0.0) return n / d
            }
        }
        return null
    }

    fun doubleValue(token: String): Double? = token.replace(",", ".").toDoubleOrNull()

    data class RangeVal(val low: Double, val high: Double, val midpoint: Double)

    /** Range "2-3" or "2–3" (en dash) → midpoint. */
    fun rangeValue(token: String): RangeVal? {
        val norm = token.replace("–", "-").replace("—", "-")
        val parts = norm.split("-")
        if (parts.size != 2) return null
        val lo = parts[0].toDoubleOrNull() ?: return null
        val hi = parts[1].toDoubleOrNull() ?: return null
        return RangeVal(lo, hi, (lo + hi) / 2.0)
    }

    data class AttachedVal(val value: Double, val whole: Int)

    /** Digit(s) with attached unicode fraction, e.g. "1½" → 1.5. */
    fun attachedUnicodeValue(token: String): AttachedVal? {
        if (token.isEmpty()) return null
        val last = token.last()
        val frac = unicodeFractions[last] ?: fractionValue(last.toString()) ?: return null
        val head = token.dropLast(1)
        if (head.isEmpty()) return AttachedVal(frac, 0)
        head.toIntOrNull()?.let { return AttachedVal(it + frac, it) }
        head.toDoubleOrNull()?.let { return AttachedVal(it + frac, it.toInt()) }
        return null
    }

    fun canonicalUnit(token: String): String? {
        val key = token.lowercase().trim('.', ',')
        return unitAliases[key]
    }

    fun buildDisplay(quantity: Double?, quantityText: String?, unit: String, name: String, fallback: String): String {
        if (name.isEmpty()) return fallback
        val parts = mutableListOf<String>()
        if (!quantityText.isNullOrEmpty()) parts.add(quantityText)
        else if (quantity != null) parts.add(fractionString(quantity))
        if (unit.isNotEmpty()) parts.add(unit)
        parts.add(name)
        if (parts.size == 1 && quantity == null && unit.isEmpty()) return fallback
        return parts.joinToString(" ")
    }

    /** Format a Double as a fraction-rounded string (1.5 → "1 1/2"). */
    fun fractionString(value: Double): String {
        val denominators = listOf(2, 3, 4, 8)
        val whole = value.toInt()
        val frac = value - whole
        if (frac < 0.03) return "$whole"
        var bestN = 0
        var bestD = 1
        var bestErr = Double.MAX_VALUE
        for (d in denominators) {
            val n = kotlin.math.round(frac * d).toInt()
            val err = kotlin.math.abs(n.toDouble() / d - frac)
            if (err < bestErr) {
                bestErr = err
                bestN = n
                bestD = d
            }
        }
        if (bestN == 0) return "$whole"
        if (bestN == bestD) return "${whole + 1}"
        val f = "$bestN/$bestD"
        return if (whole == 0) f else "$whole $f"
    }
}
