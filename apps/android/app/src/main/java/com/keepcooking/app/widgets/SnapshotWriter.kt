package com.keepcooking.app.widgets

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import com.keepcooking.app.data.AppDatabase
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Main-app helper: rebuilds the shared snapshot from Room after plan/list
 * edits and asks AppWidgetManager to refresh. Parity with iOS SnapshotWriter.
 * No network, called from a background coroutine after writes.
 */
object SnapshotWriter {
    suspend fun refresh(context: Context, db: AppDatabase) {
        val dayISO = WidgetSnapshotStore.dayISO()
        val fmt = DateTimeFormatter.ISO_DATE.withZone(ZoneOffset.UTC)
        val planItems = db.plans().livePlans().filterNot { it.deleted }.mapNotNull { plan ->
            val iso = fmt.format(Instant.ofEpochMilli(plan.date))
            if (iso != dayISO) return@mapNotNull null
            val title = when {
                plan.recipeId != null -> db.recipes().byId(plan.recipeId!!)?.title ?: plan.note.ifBlank { plan.mealRaw }
                plan.note.isNotBlank() -> plan.note
                else -> plan.mealRaw.replaceFirstChar { it.uppercase() }
            }
            PlanSnapshotItem(plan.id, iso, plan.mealRaw, title)
        }
        val listItems = db.shoppingLists().liveLists().map { list ->
            val items = db.listItems().forList(list.id).filterNot { it.deleted }
            ListProgressSnapshot(
                listId = list.id, name = list.name,
                checked = items.count { it.checked }, total = items.size,
            )
        }
        WidgetSnapshotStore.write(context, TodaySnapshot(planItems, listItems))
        requestRefresh(context)
    }

    /** Asks the launcher to re-read both widgets via update broadcast. */
    fun requestRefresh(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (cls in listOf(TodayPlanWidget::class.java, ListProgressWidget::class.java)) {
            val ids = manager.getAppWidgetIds(ComponentName(context, cls))
            if (ids.isNotEmpty()) {
                context.sendBroadcast(
                    Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
                        component = ComponentName(context, cls)
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                    },
                )
            }
        }
    }
}
