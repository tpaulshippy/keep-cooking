package com.keepcooking.app.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import com.keepcooking.app.R

/**
 * Today's Plan widget — parity with iOS TodayPlanWidget (systemSmall/Medium).
 * Reads the shared [TodaySnapshot]; never touches Room or the network.
 * Implemented with RemoteViews (no Glance dependency); layout mirrors the
 * SwiftUI TodayPlanView (header + up to 3 meal rows).
 */
class TodayPlanWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val snapshot = WidgetSnapshotStore.read(context)
        val plans = WidgetSnapshotStore.todayPlans(snapshot, WidgetSnapshotStore.dayISO()).take(3)
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_today_plan)
            if (plans.isEmpty()) {
                views.setTextViewText(R.id.widget_body, "No meals planned")
            } else {
                views.setTextViewText(
                    R.id.widget_body,
                    plans.joinToString("\n") { "${it.meal.replaceFirstChar { c -> c.uppercase() }} · ${it.title}" },
                )
            }
            manager.updateAppWidget(id, views)
        }
    }
}

/**
 * List Progress widget — parity with iOS ListProgressWidget.
 * Shows the first 2 lists with checked/total counts + progress bar.
 */
class ListProgressWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val snapshot = WidgetSnapshotStore.read(context)
        val lists = snapshot.lists.take(2)
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_list_progress)
            if (lists.isEmpty()) {
                views.setTextViewText(R.id.widget_body, "No active lists")
                views.setProgressBar(R.id.widget_progress, 100, 0, false)
            } else {
                val first = lists[0]
                views.setTextViewText(
                    R.id.widget_body,
                    lists.joinToString("\n") { "${it.name} ${it.checked}/${it.total}" },
                )
                views.setProgressBar(
                    R.id.widget_progress, 100,
                    (first.fraction * 100).toInt().coerceIn(0, 100), false,
                )
            }
            manager.updateAppWidget(id, views)
        }
    }
}
