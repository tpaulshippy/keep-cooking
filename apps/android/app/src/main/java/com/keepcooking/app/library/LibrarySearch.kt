package com.keepcooking.app.library

import com.keepcooking.app.data.RecipeEntity
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Library search engine — port of iOS Features/Library/LibrarySearch.swift.
 * Pure Kotlin (no Room/Compose) so it is unit-testable on the JVM.
 */

/** Minimal surface the search engine needs. */
interface LibraryRecipe {
    val recipeId: String
    val title: String
    val recipeDescription: String
    val servings: Double
    val prepMinutes: Int?
    val cookMinutes: Int?
    val rating: Double?
    val isFavorite: Boolean
    val source: String
    val categories: List<String>
    val ingredientNames: List<String>
    val stepTexts: List<String>
}

/** Adapter over the Room [RecipeEntity]. Callers supply ingredients/steps. */
data class RoomLibraryRecipe(
    val entity: RecipeEntity,
    override val ingredientNames: List<String> = emptyList(),
    override val stepTexts: List<String> = emptyList(),
) : LibraryRecipe {
    override val recipeId get() = entity.id
    override val title get() = entity.title
    override val recipeDescription get() = entity.recipeDescription
    override val servings get() = entity.servings
    override val prepMinutes get() = entity.prepMinutes
    override val cookMinutes get() = entity.cookMinutes
    override val rating get() = entity.rating
    override val isFavorite get() = entity.isFavorite
    override val source get() = entity.source
    override val categories: List<String>
        get() = runCatching {
            Json.decodeFromString<List<String>>(entity.categoriesJson)
        }.getOrDefault(emptyList())
}

/** Total hands-on time when either half is known. */
val LibraryRecipe.totalMinutes: Int?
    get() = when {
        prepMinutes != null && cookMinutes != null -> prepMinutes!! + cookMinutes!!
        prepMinutes != null -> prepMinutes
        cookMinutes != null -> cookMinutes
        else -> null
    }

/** Lowercased haystack: title + description + ingredients + categories + source. */
val LibraryRecipe.searchHaystack: String
    get() = (listOf(title, recipeDescription, source) + categories + ingredientNames + stepTexts)
        .joinToString(" ").lowercase()

/** Advanced filter backing Library search + SavedSearch. All fields optional. */
@Serializable
data class AdvancedFilter(
    val query: String = "",
    /** Every term must appear (AND). */
    val includeTerms: List<String> = emptyList(),
    /** No term may appear (NOT). */
    val excludeTerms: List<String> = emptyList(),
    /** Keep recipes whose total time is known and <= this (minutes). */
    val maxTotalMinutes: Int? = null,
    /** Keep recipes rated >= this. Unrated recipes never match. */
    val minRating: Double? = null,
    /** Keep only favorites. */
    val favoritesOnly: Boolean = false,
    /** Case-insensitive substring match on `source`. */
    val sourceContains: String? = null,
    /** At least one must match (case-insensitive). Empty = no constraint. */
    val categories: List<String> = emptyList(),
) {
    val isEmpty: Boolean
        get() = query.isBlank() && includeTerms.isEmpty() && excludeTerms.isEmpty() &&
            maxTotalMinutes == null && minRating == null && !favoritesOnly &&
            (sourceContains ?: "").isEmpty() && categories.isEmpty()

    fun toJson(): String = Json.encodeToString(this)

    companion object {
        fun fromJson(json: String): AdvancedFilter? = runCatching {
            Json.decodeFromString<AdvancedFilter>(json)
        }.getOrNull()
    }
}

/** True when [recipe] satisfies every constraint in [filter]. */
fun <R : LibraryRecipe> matchesFilter(recipe: R, filter: AdvancedFilter): Boolean {
    val haystack = recipe.searchHaystack
    for (token in filter.query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }) {
        if (!haystack.contains(token)) return false
    }
    for (term in filter.includeTerms) {
        val t = term.lowercase().trim()
        if (t.isNotEmpty() && !haystack.contains(t)) return false
    }
    for (term in filter.excludeTerms) {
        val t = term.lowercase().trim()
        if (t.isNotEmpty() && haystack.contains(t)) return false
    }
    filter.maxTotalMinutes?.let { cap ->
        val total = recipe.totalMinutes ?: return false
        if (total > cap) return false
    }
    filter.minRating?.let { floor ->
        val rating = recipe.rating ?: return false
        if (rating < floor) return false
    }
    if (filter.favoritesOnly && !recipe.isFavorite) return false
    filter.sourceContains?.trim()?.takeIf { it.isNotEmpty() }?.let { src ->
        if (!recipe.source.lowercase().contains(src.lowercase())) return false
    }
    if (filter.categories.isNotEmpty()) {
        val have = recipe.categories.map { it.lowercase() }.toSet()
        if (filter.categories.none { have.contains(it.lowercase()) }) return false
    }
    return true
}

/** Filters + ranks: matches first, then title-ascending for stability. */
fun <R : LibraryRecipe> filterRecipes(recipes: List<R>, filter: AdvancedFilter): List<R> =
    recipes.filter { matchesFilter(it, filter) }.sortedBy { it.title.lowercase() }
