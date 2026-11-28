package com.keepcooking.app.ingest

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Contract types for POST /clip — port of iOS ClipModels.swift.
 * Privacy: log only { strategy, host, confidence }. Never log url query
 * strings, captions, or parsed content.
 */

@Serializable
enum class ClipSource(val raw: String) {
    @SerialName("url") URL("url"),
    @SerialName("tiktok") TIKTOK("tiktok"),
    @SerialName("instagram") INSTAGRAM("instagram"),
    @SerialName("youtube") YOUTUBE("youtube"),
    @SerialName("ocr") OCR("ocr"),
    @SerialName("clipboard") CLIPBOARD("clipboard"),
    @SerialName("text") TEXT("text"),
    @SerialName("photo") PHOTO("photo"),
}

@Serializable
data class ClipRequest(
    val url: String? = null,
    val caption: String? = null,
    val source: ClipSource? = null,
)

@Serializable
enum class ClipStrategy(val raw: String) {
    @SerialName("jsonld") JSONLD("jsonld"),
    @SerialName("reader") READER("reader"),
    @SerialName("caption") CAPTION("caption"),
    @SerialName("ocr") OCR("ocr"),
}

@Serializable
data class ClipIngredientInput(
    val name: String,
    val quantity: Double? = null,
    val unit: String? = null,
    val display: String? = null,
)

@Serializable
data class ClipStepInput(val text: String)

@Serializable
data class ClipRecipeInput(
    val title: String,
    val description: String? = null,
    val servings: Double? = null,
    val prepMinutes: Int? = null,
    val cookMinutes: Int? = null,
    val source: String? = null,
    val sourceUrl: String? = null,
    val categories: List<String>? = null,
    val ingredients: List<ClipIngredientInput>? = null,
    val steps: List<ClipStepInput>? = null,
)

@Serializable
data class ClipReport(
    val strategy: ClipStrategy,
    val confidence: Double? = null,
    val warnings: List<String>? = null,
    val sourceUrl: String? = null,
    val recipe: ClipRecipeInput,
)

/** What we log per clip: strategy + host + confidence only. */
data class ClipLogEvent(
    val strategy: ClipStrategy,
    val host: String,
    val confidence: Double,
) {
    val description: String get() = "clip strategy=${strategy.raw} host=$host confidence=$confidence"
}

fun clipHost(from: String?): String {
    if (from.isNullOrEmpty()) return "caption-only"
    return runCatching { java.net.URI(from).host ?: "caption-only" }.getOrDefault("caption-only")
}

/** Server-error message for HTTP statuses, else null so callers keep context-specific copy. */
fun clipServerErrorMessage(statusCode: Int?): String? =
    if (statusCode != null) "The recipe service returned an error ($statusCode). Try again later." else null

/** Human-readable text for a ClipReport warning code. Unknown codes pass through. */
fun clipWarningText(warning: String): String = when (warning) {
    "jsonld-missing" -> "No recipe card found on the page — details were read from the page text instead."
    else -> warning
}

/** Title gating shared by ingest Save buttons. */
fun isSavableTitle(title: String): Boolean = title.trim().isNotEmpty()

/** Trims the saved title the same way isSavableTitle validates it. */
fun cleanTitle(title: String): String = title.trim()
