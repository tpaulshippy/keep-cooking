package com.keepcooking.app.wear

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Watch companion data layer — parity with iOS watch/WatchViews.swift.
 *
 * Data contract (SharedPreferences file "keepcooking_watch"):
 *   `smidgen.snapshot.v1`   -> TodaySnapshot (lists + plans; see widgets)
 *   `smidgen.nowcooking.v1`  -> NowCookingPayload (steps + timers, JSON)
 * The phone writes NowCookingPayload when Cook mode starts a recipe; the
 * watch (or the Wear OS stub screens below) only reads.
 */
@Serializable
data class WatchStepItem(val position: Int, val text: String, val done: Boolean = false)

@Serializable
data class WatchTimerItem(val label: String, val seconds: Int) {
    val display: String get() = "%d:%02d".format(seconds / 60, seconds % 60)
}

@Serializable
data class NowCookingPayload(
    val recipeId: String,
    val title: String,
    val steps: List<WatchStepItem> = emptyList(),
    val timers: List<WatchTimerItem> = emptyList(),
    val updatedAtMillis: Long = System.currentTimeMillis(),
)

object WatchStore {
    const val PREFS = "keepcooking_watch"
    const val NOW_COOKING_KEY = "smidgen.nowcooking.v1"

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** Never throws: missing/corrupt payload yields null (views show empty state). */
    fun readNowCooking(context: Context): NowCookingPayload? {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(NOW_COOKING_KEY, null) ?: return null
        return runCatching { json.decodeFromString<NowCookingPayload>(raw) }.getOrNull()
    }

    fun writeNowCooking(context: Context, payload: NowCookingPayload) {
        runCatching {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(NOW_COOKING_KEY, json.encodeToString(payload))
                .apply()
        }
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(NOW_COOKING_KEY).apply()
    }
}
