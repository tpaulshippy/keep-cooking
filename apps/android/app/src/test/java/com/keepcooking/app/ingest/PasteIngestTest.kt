package com.keepcooking.app.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Paste-tab splitter path: free pasted text → [OcrSplitter.split].
 * Same splitter the Paste tab's Parse button uses (title = first line,
 * quantity-led lines → ingredients, the rest → steps).
 */
class PasteIngestTest {

    @Test fun `paste free text splits title ingredients steps`() {
        val text = "Weeknight Miso Salmon\n4 salmon fillets\n3 tbsp white miso\nHeat oven to 220C.\nWhisk miso and glaze."
        val draft = OcrSplitter.split(text.split("\n"))
        assertEquals("Weeknight Miso Salmon", draft.title)
        assertEquals(listOf("4 salmon fillets", "3 tbsp white miso"), draft.ingredientLines)
        assertEquals(listOf("Heat oven to 220C.", "Whisk miso and glaze."), draft.stepLines)
    }

    @Test fun `paste text title trimmed and blanks skipped`() {
        val draft = OcrSplitter.split(listOf("  Soup  ", "", "1 cup rice", "salt to taste"))
        assertEquals("Soup", draft.title)
        assertEquals(listOf("1 cup rice"), draft.ingredientLines)
        assertEquals(listOf("salt to taste"), draft.stepLines)
    }

    @Test fun `paste empty text yields empty draft`() {
        val draft = OcrSplitter.split(listOf("", "   "))
        assertEquals("", draft.title)
        assertTrue(draft.ingredientLines.isEmpty())
        assertTrue(draft.stepLines.isEmpty())
    }

    @Test fun `paste title-only text is savable guard input`() {
        val draft = OcrSplitter.split(listOf("Just a title"))
        assertEquals("Just a title", draft.title)
        assertTrue(isSavableTitle(draft.title))
        assertEquals("Just a title", cleanTitle("  Just a title  "))
    }
}
