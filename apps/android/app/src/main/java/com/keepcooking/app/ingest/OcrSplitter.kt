package com.keepcooking.app.ingest

/**
 * Heuristic splitter: OCR lines → title/ingredients/steps.
 * Port of iOS OCRSplitter in OCRScanView.swift.
 */
data class OcrDraft(
    val title: String,
    val ingredientLines: List<String> = emptyList(),
    val stepLines: List<String> = emptyList(),
)

object OcrSplitter {
    /**
     * First non-empty line = title. Lines with a leading quantity parse as
     * ingredients; the rest become steps.
     */
    fun split(lines: List<String>): OcrDraft {
        val cleaned = lines.map { it.trim() }.filter { it.isNotEmpty() }
        val first = cleaned.firstOrNull() ?: return OcrDraft("")
        val ings = mutableListOf<String>()
        val steps = mutableListOf<String>()
        for (line in cleaned.drop(1)) {
            val p = IngredientParser.parse(line)
            if (p.quantity != null && p.name.isNotEmpty()) ings.add(p.display)
            else steps.add(line)
        }
        return OcrDraft(title = first, ingredientLines = ings, stepLines = steps)
    }
}
