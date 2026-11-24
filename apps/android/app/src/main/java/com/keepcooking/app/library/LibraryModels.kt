package com.keepcooking.app.library

import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Library models — port of iOS Features/Library/LibraryModels.swift.
 *
 * Cookbooks / SavedSearches are plain data classes here; Room tables for
 * them can be added later. JSON helpers mirror the SwiftData string columns.
 */

/** A named collection of recipes. Membership is a JSON id array. */
@Serializable
data class Cookbook(
    val id: String = UUID.randomUUID().toString(),
    val householdId: String,
    val name: String,
    val recipeIds: List<String> = emptyList(),
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) {
    fun toIdsJson(): String = Json.encodeToString(recipeIds)

    companion object {
        fun idsFromJson(json: String): List<String> =
            runCatching { Json.decodeFromString<List<String>>(json) }.getOrDefault(emptyList())
    }
}

/** A named [AdvancedFilter]. Local-only by design (never synced). */
@Serializable
data class SavedSearch(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val filter: AdvancedFilter = AdvancedFilter(),
    val createdAt: Long = System.currentTimeMillis(),
) {
    fun toFilterJson(): String = filter.toJson()

    companion object {
        fun filterFromJson(json: String): AdvancedFilter? = AdvancedFilter.fromJson(json)
    }
}

/**
 * Household invite: created on-device, shared out-of-band.
 * Deep link shape `keepcooking://invite/<code>` is fixed for the server route.
 */
@Serializable
data class HouseholdInvite(
    val id: String = UUID.randomUUID().toString(),
    val householdId: String,
    val code: String,
    val createdAt: Long = System.currentTimeMillis(),
    val expiresAt: Long = System.currentTimeMillis() + 7 * 86_400_000L,
    val maxUses: Int = 5,
    val useCount: Int = 0,
) {
    val isExpired: Boolean
        get() = System.currentTimeMillis() > expiresAt || useCount >= maxUses

    val inviteUrl: String get() = "keepcooking://invite/$code"

    companion object {
        private const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

        fun make(householdId: String): HouseholdInvite {
            val code = (1..8).map { ALPHABET.random() }.joinToString("")
            return HouseholdInvite(householdId = householdId, code = code)
        }
    }
}

/** Cookbook share link returned by `POST /share/cookbook`. */
@Serializable
data class ShareLink(
    val id: String,
    val url: String,
    val expiresAt: String,
)
