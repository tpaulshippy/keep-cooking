package com.keepcooking.app

import com.keepcooking.app.ui.screens.importFormatForExtension
import com.keepcooking.app.ui.screens.serverImportFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Cubic findings 2+3: only server-parseable formats go to POST /import. */
class ImportServerFormatTest {

    @Test
    fun `server parses paprika yaml html families`() {
        assertEquals("paprika-zip", serverImportFormat("paprikarecipe"))
        assertEquals("paprika-zip", serverImportFormat("paprikarecipes"))
        assertEquals("paprika-zip", serverImportFormat("zip"))
        assertEquals("paprika-json", serverImportFormat("json"))
        assertEquals("yaml", serverImportFormat("yml"))
        assertEquals("yaml", serverImportFormat("yaml"))
        assertEquals("html", serverImportFormat("html"))
        assertEquals("html", serverImportFormat("htm"))
    }

    @Test
    fun `third-party formats skip the server for offline parse`() {
        // P1 415s (mx2/mxp/mz2/mmf/fdx/fdxz) and unknown sniff-as-YAML
        // 200-with-0-imported (xml/mcb/txt/…) must never be sent.
        for (ext in listOf("mx2", "mxp", "mz2", "mmf", "fdx", "fdxz", "xml", "mcb", "txt", "db", "rbox", "foo")) {
            assertNull(".$ext should parse offline, got ${serverImportFormat(ext)}", serverImportFormat(ext))
        }
    }

    @Test
    fun `legacy alias matches server gate`() {
        for (ext in listOf("paprikarecipe", "json", "yaml", "html", "xml", "mcb", "txt", "mx2")) {
            assertEquals(ext, serverImportFormat(ext), importFormatForExtension(ext))
        }
    }
}
