package com.keepcooking.app.ingest

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wire-value tests for the clip contract (packages/contracts/openapi.yaml:
 * ClipRequest.source in [url, tiktok, instagram, youtube, ocr, clipboard, text, photo],
 * ClipReport.strategy in [jsonld, reader, caption, ocr]).
 * Without @SerialName the Kotlin entries serialize as "URL"/"TIKTOK"/... and
 * the server (zod enum) rejects the request while lowercase responses fail
 * to decode.
 */
class ClipModelsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun `clip source serializes lowercase`() {
        val wire = Json.encodeToString(
            ClipRequest.serializer(),
            ClipRequest(url = "https://example.com/r", source = ClipSource.TIKTOK),
        )
        assertTrue("request must send \"tiktok\": $wire", wire.contains("\"source\":\"tiktok\""))
        for (entry in ClipSource.entries) {
            val w = Json.encodeToString(ClipRequest.serializer(), ClipRequest(source = entry))
            assertTrue("expected lowercase ${entry.raw} in $w", w.contains("\"source\":\"${entry.raw}\""))
        }
    }

    @Test fun `clip source decodes lowercase`() {
        val req = json.decodeFromString(
            ClipRequest.serializer(),
            """{"url":"https://example.com/r","source":"url"}""",
        )
        assertEquals(ClipSource.URL, req.source)
        assertEquals(
            ClipSource.TEXT,
            json.decodeFromString(ClipRequest.serializer(), """{"source":"text"}""").source,
        )
        assertEquals(
            ClipSource.PHOTO,
            json.decodeFromString(ClipRequest.serializer(), """{"source":"photo"}""").source,
        )
    }

    @Test fun `clip strategy decodes lowercase`() {
        val report = json.decodeFromString(
            ClipReport.serializer(),
            """{"strategy":"jsonld","confidence":0.9,"recipe":{"title":"Soup"}}""",
        )
        assertEquals(ClipStrategy.JSONLD, report.strategy)
        assertEquals("Soup", report.recipe.title)
    }

    @Test fun `clip strategy serializes lowercase`() {
        for (entry in ClipStrategy.entries) {
            val report = ClipReport(strategy = entry, recipe = ClipRecipeInput(title = "T"))
            val w = Json.encodeToString(ClipReport.serializer(), report)
            assertTrue("expected lowercase ${entry.raw} in $w", w.contains("\"strategy\":\"${entry.raw}\""))
        }
    }
}
