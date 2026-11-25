package com.keepcooking.app.ingest

/**
 * Clipboard auto-detect — port of iOS ClipboardDetector in ClipboardBanner.swift.
 * Pure detector; the UI reads the system clipboard and shows a banner.
 * Never auto-imports without consent.
 */
object ClipboardDetector {
    private val urlPattern = Regex("https?://[^\\s]+")

    /** Returns the URL string if text contains an http(s) URL, else null. */
    fun firstUrl(inText: String): String? {
        val m = urlPattern.find(inText) ?: return null
        return m.value.trimEnd('.', ',', ')', ';', '"', '\'').ifEmpty { null }
    }

    /** Heuristic: looks like a recipe share (URL or >= 2 lines with >= 1 quantity). */
    fun looksLikeRecipe(text: String): Boolean {
        if (firstUrl(text) != null) return true
        val lines = text.split("\n").map { it.trim() }.filter { it.isNotEmpty() }
        if (lines.size < 2) return false
        return lines.count { IngredientParser.parse(it).quantity != null } >= 1
    }
}
