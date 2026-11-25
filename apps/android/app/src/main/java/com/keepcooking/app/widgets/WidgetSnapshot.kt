package com.keepcooking.app.widgets

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Shared snapshot powering widgets + watch + shortcuts without touching
 * Room outside the main app. Parity with iOS Widgets/WidgetSnapshot.swift.
 *
 * Storage: SharedPreferences file "keepcooking_snapshot", key
 * `smidgen.snapshot.v1`. Reads never throw: corrupt/missing data yields empty.
 */
@Serializable
data class PlanSnapshotItem(
    val id: String,
    val dateISO: String, // YYYY-MM-DD
    val meal: String,
    val title: String, // recipe title, note, or meal fallback
)

@Serializable
data class ListProgressSnapshot(
    val listId: String,
    val name: String,
    val checked: Int,
    val total: Int,
) {
    val fraction: Float get() = if (total > 0) checked.toFloat() / total else 0f
}

@Serializable
data class TodaySnapshot(
    val plans: List<PlanSnapshotItem> = emptyList(),
    val lists: List<ListProgressSnapshot> = emptyList(),
    val updatedAtMillis: Long = System.currentTimeMillis(),
) {
    companion object {
        val EMPTY = TodaySnapshot()
        fun preview() = TodaySnapshot(
            plans = listOf(
                PlanSnapshotItem("p1", WidgetSnapshotStore.dayISO(), "breakfast", "Blueberry Pancakes"),
                PlanSnapshotItem("p2", WidgetSnapshotStore.dayISO(), "dinner", "Weeknight Miso Salmon"),
            ),
            lists = listOf(ListProgressSnapshot("l1", "Weekly shop", 7, 12)),
        )
    }
}

object WidgetSnapshotStore {
    const val PREFS = "keepcooking_snapshot"
    const val SNAPSHOT_KEY = "smidgen.snapshot.v1"

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun write(context: Context, snapshot: TodaySnapshot) {
        runCatching {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(SNAPSHOT_KEY, json.encodeToString(snapshot))
                .apply()
        }
    }

    /** Never throws: corrupt/missing data yields [TodaySnapshot.EMPTY]. */
    fun read(context: Context): TodaySnapshot {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(SNAPSHOT_KEY, null) ?: return TodaySnapshot.EMPTY
        return runCatching { json.decodeFromString<TodaySnapshot>(raw) }
            .getOrDefault(TodaySnapshot.EMPTY)
    }

    /** Today's plans in canonical meal order (breakfast→lunch→dinner→snack). */
    fun todayPlans(snapshot: TodaySnapshot, dayISO: String): List<PlanSnapshotItem> {
        val order = mapOf("breakfast" to 0, "lunch" to 1, "dinner" to 2, "snack" to 3)
        return snapshot.plans.filter { it.dateISO == dayISO }
            .sortedBy { order[it.meal.lowercase()] ?: 99 }
    }

    fun dayISO(): String =
        LocalDate.now(ZoneOffset.UTC).format(DateTimeFormatter.ISO_DATE)
}
