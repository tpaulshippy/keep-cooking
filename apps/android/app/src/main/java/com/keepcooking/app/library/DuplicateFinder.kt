package com.keepcooking.app.library

/**
 * Fuzzy duplicate detection + merge — port of iOS DuplicateFinder.swift.
 * Pure Kotlin (no Room/Compose); unit-tested directly.
 *
 * A pair is a duplicate when ANY of these hold:
 *   (a) title token Jaccard >= 0.5 after normalization, or
 *   (b) normalized-title Levenshtein similarity >= 0.8, or
 *   (c) stripped copy-markers agree ("Copy of X", "X (1)"), or
 *   (d) explicit reference ("dup of 09" names the other record), or
 *   (e) content signature Jaccard >= 0.8 with >= 6 content tokens per side.
 *
 * INTENTIONAL DIVERGENCE from iOS DuplicateFinder.swift (cubic round-2 P2;
 * mirroring to Swift deferred — do not "fix" one side without the other):
 *   - Blank titles: Android requires non-empty normalized titles on BOTH
 *     sides before applying the title signals (a); iOS applies them
 *     unconditionally, so two blank/punctuation-only titles match there
 *     (jaccard([],[]) == 1.0). Android is stricter (never matches blanks).
 *   - Exact-match references: Android's referencesOther only matches when
 *     the fragment equals the other's full normalized title or an id
 *     suffix; iOS additionally accepts a title-token hit or a title
 *     substring (len >= 3), e.g. "dup of choc" matches "Chocolate Chip
 *     Cookies" on iOS but not on Android. Android is stricter.
 */

/** Minimal surface the finder needs. */
interface DuplicableRecipe {
    val recipeId: String
    val title: String
    val rating: Double?
    val categories: List<String>
    val ingredientNames: List<String>
    val stepTexts: List<String>
    val photoOriginal: String?
    val photoThumb: String?
}

private val abbreviationExpansions: Map<String, String> = mapOf(
    "choc" to "chocolate",
    "veg" to "vegetable",
    "veggie" to "vegetable",
    "parm" to "parmesan",
    "mozz" to "mozzarella",
)

/** Lowercases, strips punctuation, expands abbreviations, splits on whitespace. */
fun titleTokens(title: String): List<String> {
    val cleaned = title.lowercase().map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("")
    return cleaned.split(" ").filter { it.isNotEmpty() }.map { abbreviationExpansions[it] ?: it }
}

/** Normalized title string for edit-distance comparison. */
fun normalizedTitle(title: String): String = titleTokens(title).joinToString(" ")

/** Jaccard similarity over token multisets, 0...1. */
fun jaccard(a: List<String>, b: List<String>): Double {
    if (a.isEmpty() && b.isEmpty()) return 1.0
    val countsA = a.groupingBy { it }.eachCount()
    val countsB = b.groupingBy { it }.eachCount()
    var intersection = 0
    var union = 0
    for (key in countsA.keys + countsB.keys) {
        intersection += minOf(countsA[key] ?: 0, countsB[key] ?: 0)
        union += maxOf(countsA[key] ?: 0, countsB[key] ?: 0)
    }
    if (union == 0) return 1.0
    return intersection.toDouble() / union.toDouble()
}

/** Levenshtein distance over characters. */
fun levenshtein(a: String, b: String): Int {
    if (a.isEmpty()) return b.length
    if (b.isEmpty()) return a.length
    var prev = IntArray(b.length + 1) { it }
    for (i in 1..a.length) {
        val cur = IntArray(b.length + 1)
        cur[0] = i
        for (j in 1..b.length) {
            cur[j] = if (a[i - 1] == b[j - 1]) prev[j - 1]
            else 1 + minOf(prev[j - 1], prev[j], cur[j - 1])
        }
        prev = cur
    }
    return prev[b.length]
}

/** 1 - (distance / maxLength); identical strings score 1. */
fun levenshteinSimilarity(a: String, b: String): Double {
    val longest = maxOf(a.length, b.length)
    if (longest == 0) return 1.0
    return 1.0 - levenshtein(a, b).toDouble() / longest.toDouble()
}

data class DuplicateThresholds(
    val titleJaccard: Double = 0.5,
    val titleEditSimilarity: Double = 0.8,
    val contentJaccard: Double = 0.8,
)

private fun <R : DuplicableRecipe> contentTokens(r: R): List<String> {
    val ings = r.ingredientNames.map { it.lowercase().trim() }
    val steps = r.stepTexts.flatMap { it.lowercase().split(Regex("\\s+")).filter { t -> t.isNotEmpty() } }
    return ings + steps
}

/** True when the pair counts as duplicates under any signal. */
fun <R : DuplicableRecipe> isDuplicatePair(
    a: R,
    b: R,
    thresholds: DuplicateThresholds = DuplicateThresholds(),
): Boolean {
    if (a.recipeId == b.recipeId) return false
    // Title signals need real text on BOTH sides: blank or punctuation-only
    // titles normalize to "" (jaccard([],[]) and similarity("","") both score
    // 1.0), which must never count as a match.
    val normA = normalizedTitle(a.title)
    val normB = normalizedTitle(b.title)
    if (normA.isNotEmpty() && normB.isNotEmpty()) {
        if (jaccard(titleTokens(a.title), titleTokens(b.title)) >= thresholds.titleJaccard) return true
        if (levenshteinSimilarity(normA, normB) >= thresholds.titleEditSimilarity) return true
    }
    val sa = strippedCopyTitle(a.title)
    val sb = strippedCopyTitle(b.title)
    if (sa.isNotEmpty() && sa == sb) return true
    if (referencesOther(a.title, b) || referencesOther(b.title, a)) return true
    val ca = contentTokens(a)
    val cb = contentTokens(b)
    if (ca.size >= 6 && cb.size >= 6 && jaccard(ca, cb) >= thresholds.contentJaccard) return true
    return false
}

/** Removes importer copy markers: "copy of X" -> "X", "X (1)" -> "X". */
fun strippedCopyTitle(title: String): String {
    var s = title.replace(Regex("\\s*\\(\\d+\\)\\s*$"), "")
    s = normalizedTitle(s)
    for (prefix in listOf("copy of ", "copy ", "duplicate of ", "duplicate ")) {
        if (s.startsWith(prefix)) {
            s = s.drop(prefix.length)
            break
        }
    }
    s = s.replace(Regex("\\s*\\(\\d+\\)\\s*$"), "")
    s = s.replace(Regex("\\s+-\\s+copy\\s*$"), "")
    return s.trim()
}

/** Parses "dup of <ref>" / "duplicate of <ref>" / "copy of <ref>" titles. */
fun referenceFragment(title: String): String? {
    val s = normalizedTitle(title).trim()
    val m = Regex("^(?:dup(?:licate)?|copy)(?:\\s+of)?\\s+(.+)$").find(s) ?: return null
    val ref = m.groupValues[1].trim()
    return ref.ifEmpty { null }
}

/**
 * True when [title] explicitly references [other]: the reference fragment
 * (from [referenceFragment]) must equal the other's full normalized title or
 * match the tail of its record id. Substring/token-substring hits do NOT
 * count — "dup of choc" must not claim "Chocolate Chip Cookies".
 */
private fun <R : DuplicableRecipe> referencesOther(title: String, other: R): Boolean {
    val ref = referenceFragment(title) ?: return false
    if (ref.length < 2) return false
    val lower = ref.lowercase()
    if (other.recipeId.lowercase().endsWith(lower)) return true
    if (normalizedTitle(other.title).isNotEmpty() && normalizedTitle(other.title) == lower) return true
    return false
}

/**
 * Groups recipes into duplicate clusters (each group has >= 2 members).
 * Deterministic: groups and members are sorted by id.
 */
fun <R : DuplicableRecipe> findDuplicateGroups(
    recipes: List<R>,
    thresholds: DuplicateThresholds = DuplicateThresholds(),
): List<List<R>> {
    val sorted = recipes.sortedBy { it.recipeId }
    val parent = sorted.associate { it.recipeId to it.recipeId }.toMutableMap()
    fun find(x: String): String {
        var root = x
        while (parent[root] != root) root = parent[root] ?: root
        return root
    }
    fun union(x: String, y: String) {
        val rx = find(x)
        val ry = find(y)
        if (rx != ry) parent[maxOf(rx, ry)] = minOf(rx, ry)
    }
    for (i in sorted.indices) {
        for (j in i + 1 until sorted.size) {
            if (isDuplicatePair(sorted[i], sorted[j], thresholds)) {
                union(sorted[i].recipeId, sorted[j].recipeId)
            }
        }
    }
    val clusters = mutableMapOf<String, MutableList<R>>()
    for (r in sorted) clusters.getOrPut(find(r.recipeId)) { mutableListOf() }.add(r)
    return clusters.values.filter { it.size >= 2 }
        .sortedBy { it.firstOrNull()?.recipeId ?: "" }
}

/** Merge instruction for a duplicate group: which record survives and what it absorbs. */
data class DuplicateMergePlan(
    /** Survivor id. */
    val survivorId: String,
    /** Ids to tombstone/delete after merging. */
    val absorbedIds: List<String>,
    /** Union of categories across the group (sorted, deduped, lowercased). */
    val mergedCategories: List<String>,
    /** Union of ingredient display strings (case-insensitive dedup, sorted). */
    val mergedIngredientNames: List<String>,
    /** Best (longest non-empty) photo key in the group, if any. */
    val bestPhotoOriginal: String?,
    val bestPhotoThumb: String?,
    /** Highest rating in the group, if any. */
    val bestRating: Double?,
    /** Title of the survivor (longest original title — most descriptive). */
    val survivorTitle: String,
)

/** Picks the survivor and unions ingredients + categories. */
fun <R : DuplicableRecipe> planMerge(group: List<R>): DuplicateMergePlan? {
    if (group.size < 2) return null
    val ranked = group.sortedWith(
        compareByDescending<R> { it.ingredientNames.size }
            .thenByDescending { if (!it.photoOriginal.isNullOrEmpty()) 1 else 0 }
            .thenByDescending { it.rating ?: -1.0 }
            .thenBy { it.recipeId },
    )
    val survivor = ranked.first()
    val seen = mutableSetOf<String>()
    val mergedIngs = mutableListOf<String>()
    for (r in ranked) {
        for (name in r.ingredientNames) {
            val key = name.lowercase().trim()
            if (key.isNotEmpty() && seen.add(key)) mergedIngs.add(name.trim())
        }
    }
    mergedIngs.sortWith { a, b -> a.compareTo(b, ignoreCase = true) }
    val mergedCats = ranked.flatMap { it.categories.map { c -> c.lowercase() } }.toSortedSet().toList()
    val bestPhoto = ranked.mapNotNull { it.photoOriginal }.filter { it.isNotEmpty() }.maxByOrNull { it.length }
    val bestThumb = ranked.mapNotNull { it.photoThumb }.filter { it.isNotEmpty() }.maxByOrNull { it.length }
    val bestRating = ranked.mapNotNull { it.rating }.maxOrNull()
    val survivorTitle = ranked.map { it.title }.maxByOrNull { it.length } ?: survivor.title
    return DuplicateMergePlan(
        survivorId = survivor.recipeId,
        absorbedIds = ranked.drop(1).map { it.recipeId }.sorted(),
        mergedCategories = mergedCats,
        mergedIngredientNames = mergedIngs,
        bestPhotoOriginal = bestPhoto,
        bestPhotoThumb = bestThumb,
        bestRating = bestRating,
        survivorTitle = survivorTitle,
    )
}
