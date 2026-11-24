package com.keepcooking.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keepcooking.app.cook.fractionDisplayString
import com.keepcooking.app.plan.PlanGroceryInput
import com.keepcooking.app.plan.aggregateWeekToList
import com.keepcooking.app.plan.planFeedSubscribeUrl
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.FormatStyle
import java.time.temporal.TemporalAdjusters

private data class DemoPlanEntry(
    val id: String,
    val date: LocalDate,
    val meal: String,
    val recipeTitle: String?,
    val note: String,
    val servings: Double?,
)

private data class DemoMenu(val id: String, val name: String, val entryCount: Int)

private enum class PlanSpan { DAY, WEEK, MONTH }

/**
 * Plan tab — parity with iOS Features/Plan/PlanViews.swift.
 * Day/week/month views, reusable menus, add-week-to-list, webcal feed link.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlanScreen() {
    var span by remember { mutableStateOf(PlanSpan.WEEK) }
    var anchor by remember { mutableStateOf(LocalDate.now()) }
    var aggResult by remember { mutableStateOf<String?>(null) }

    val entries = remember {
        val monday = LocalDate.now().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
        listOf(
            DemoPlanEntry("p1", monday, "dinner", "Weeknight Pasta", "", 4.0),
            DemoPlanEntry("p2", monday.plusDays(1), "dinner", "Tacos", "", 6.0),
            DemoPlanEntry("p3", monday.plusDays(3), "lunch", null, "Leftovers", null),
            DemoPlanEntry("p4", monday.plusDays(5), "breakfast", "Pancakes", "", 2.0),
        )
    }
    val menus = remember {
        listOf(
            DemoMenu("m1", "Easy weeknights", 5),
            DemoMenu("m2", "Sunday batch", 3),
        )
    }
    val feedUrl = remember { planFeedSubscribeUrl("https://api.keepcooking.app", "household-1") }

    val weekStart = anchor.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    val spanTitle = when (span) {
        PlanSpan.DAY -> anchor.format(java.time.format.DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
        PlanSpan.WEEK -> "Week of ${weekStart.format(java.time.format.DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))}"
        PlanSpan.MONTH -> "${anchor.month.name.lowercase().replaceFirstChar { it.uppercase() }} ${anchor.year}"
    }

    fun entriesFor(day: LocalDate) = entries.filter { it.date == day }

    Scaffold(topBar = { TopAppBar(title = { Text("Plan") }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp)) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                PlanSpan.entries.forEachIndexed { idx, s ->
                    SegmentedButton(
                        selected = span == s,
                        onClick = { span = s },
                        shape = androidx.compose.material3.SegmentedButtonDefaults.itemShape(idx, PlanSpan.entries.size),
                        label = { Text(s.name.lowercase().replaceFirstChar { it.uppercase() }) },
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { anchor = anchor.minusDays(if (span == PlanSpan.MONTH) 30 else if (span == PlanSpan.WEEK) 7 else 1) }) {
                    Text("‹")
                }
                Text(spanTitle, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                OutlinedButton(onClick = { anchor = LocalDate.now() }) { Text("Today") }
                OutlinedButton(onClick = { anchor = anchor.plusDays(if (span == PlanSpan.MONTH) 30 else if (span == PlanSpan.WEEK) 7 else 1) }) {
                    Text("›")
                }
            }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = {
                    // Aggregate the visible week's entries into list lines.
                    val days = (0..6).map { weekStart.plusDays(it.toLong()) }.toSet()
                    val inputs = entries.filter { it.date in days }.map {
                        PlanGroceryInput(
                            name = it.recipeTitle ?: it.note.ifEmpty { it.meal },
                            quantity = 1.0,
                            unit = "x",
                            baseServings = 4.0,
                            targetServings = it.servings,
                            recipeId = it.id,
                        )
                    }
                    val lines = aggregateWeekToList(inputs)
                    aggResult = if (lines.isEmpty()) "Nothing planned this week." else "${lines.size} line(s): ${lines.joinToString { it.display }}"
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Add week to list") }
            aggResult?.let {
                Spacer(Modifier.height(8.dp))
                Card { Text(it, modifier = Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium) }
            }
            Spacer(Modifier.height(12.dp))

            val daysToShow: List<LocalDate> = when (span) {
                PlanSpan.DAY -> listOf(anchor)
                PlanSpan.WEEK -> (0..6).map { weekStart.plusDays(it.toLong()) }
                PlanSpan.MONTH -> {
                    val first = anchor.withDayOfMonth(1)
                    (0 until anchor.lengthOfMonth()).map { first.plusDays(it.toLong()) }
                }
            }
            daysToShow.forEach { day ->
                val dayEntries = entriesFor(day)
                Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Column(Modifier.padding(12.dp)) {
                        Text(
                            day.format(java.time.format.DateTimeFormatter.ofPattern("EEE, MMM d")),
                            style = MaterialTheme.typography.titleSmall,
                        )
                        if (dayEntries.isEmpty()) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("No meals planned", color = MaterialTheme.colorScheme.secondary, modifier = Modifier.weight(1f))
                                OutlinedButton(onClick = {}) { Text("+ Add") }
                            }
                        } else {
                            dayEntries.forEach { e ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text(e.meal.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.bodyLarge)
                                        val detail = e.recipeTitle ?: e.note
                                        if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall)
                                    }
                                    e.servings?.let {
                                        Text("${fractionDisplayString(it)} servings", style = MaterialTheme.typography.labelSmall)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (menus.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text("Reusable menus", style = MaterialTheme.typography.titleMedium)
                menus.forEach { menu ->
                    Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(menu.name, style = MaterialTheme.typography.bodyLarge)
                                Text("${menu.entryCount} entries", style = MaterialTheme.typography.labelSmall)
                            }
                            OutlinedButton(onClick = { aggResult = "“${menu.name}” applied to week of $weekStart." }) {
                                Text("Apply to week")
                            }
                        }
                    }
                }
            }

            feedUrl?.let { url ->
                Spacer(Modifier.height(8.dp))
                Text("Calendar", style = MaterialTheme.typography.titleMedium)
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text("Subscribe in Calendar (webcal)", style = MaterialTheme.typography.bodyLarge)
                        Text(url, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                    }
                }
            }
            Spacer(Modifier.height(56.dp))
        }
    }
}
