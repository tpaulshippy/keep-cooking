package com.keepcooking.app.ui.screens

import android.content.Intent
import android.net.Uri
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.keepcooking.app.AppContainer
import com.keepcooking.app.cook.fractionDisplayString
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.ListItemEntity
import com.keepcooking.app.data.MenuEntity
import com.keepcooking.app.data.MenuEntry
import com.keepcooking.app.data.PlanEntity
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.ShoppingListEntity
import com.keepcooking.app.network.SyncEnvelopeDto
import com.keepcooking.app.plan.PlanGroceryInput
import com.keepcooking.app.plan.aggregateWeekToList
import com.keepcooking.app.plan.planFeedSubscribeUrl
import com.keepcooking.app.widgets.SnapshotWriter
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.TemporalAdjusters
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

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

private val planJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

private fun PlanEntity.localDate(): LocalDate =
    Instant.ofEpochMilli(date).atZone(ZoneOffset.UTC).toLocalDate()

private fun menuEntriesOf(menu: MenuEntity): List<MenuEntry> =
    runCatching {
        planJson.decodeFromString<List<MenuEntry>>(
            kotlinx.serialization.builtins.ListSerializer(MenuEntry.serializer()),
            menu.entriesJson,
        )
    }.getOrDefault(emptyList())

/**
 * Plan tab — parity with iOS Features/Plan/PlanViews.swift.
 * Day/week/month views, reusable menus, add-week-to-list, webcal feed link.
 *
 * Menu applies + week-to-list aggregation persist to Room (PlanDao /
 * ShoppingListDao + ListItemDao) and enqueue sync outbox envelopes; the
 * widget snapshot refreshes after every write.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlanScreen(container: AppContainer? = null) {
    var span by remember { mutableStateOf(PlanSpan.WEEK) }
    var anchor by remember { mutableStateOf(LocalDate.now()) }
    var aggResult by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var plans by remember { mutableStateOf(listOf<PlanEntity>()) }
    var menus by remember { mutableStateOf(listOf<MenuEntity>()) }
    var recipesById by remember { mutableStateOf(mapOf<String, RecipeEntity>()) }
    var ingredientsByRecipe by remember { mutableStateOf(mapOf<String, List<IngredientEntity>>()) }
    var deviceId by remember { mutableStateOf("") }
    LaunchedEffect(container) {
        val db = container?.db ?: return@LaunchedEffect
        deviceId = runCatching { container.syncEngine.deviceId() }.getOrDefault("")
        plans = db.plans().livePlans()
        menus = db.menus().liveMenus()
        val recs = db.recipes().liveRecipes()
        recipesById = recs.associateBy { it.id }
        ingredientsByRecipe = recs.associate { it.id to db.ingredients().forRecipe(it.id).filterNot { ing -> ing.deleted } }
    }

    suspend fun refreshSnapshot() {
        val db = container?.db ?: return
        runCatching { SnapshotWriter.refresh(context, db) }
    }

    fun applyMenu(menu: MenuEntity, weekStart: LocalDate) {
        val db = container?.db ?: return
        val entries = menuEntriesOf(menu)
        if (entries.isEmpty()) {
            aggResult = "“${menu.name}” has no entries to apply."
            return
        }
        scope.launch {
            runCatching {
                val now = System.currentTimeMillis()
                val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
                val rows = entries.map { e ->
                    val day = weekStart.plusDays(e.dayOffset.toLong())
                    val millis = day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
                    PlanEntity(
                        id = UUID.randomUUID().toString(),
                        householdId = menu.householdId,
                        date = millis,
                        mealRaw = e.meal,
                        recipeId = e.recipeId,
                        note = "",
                        servings = e.servings,
                        updatedAt = now,
                        deviceId = did,
                    )
                }
                db.plans().upsertAll(rows)
                for (row in rows) {
                    container.syncEngine.enqueue(
                        SyncEnvelopeDto(
                            id = row.id,
                            updatedAt = Instant.ofEpochMilli(now).toString(),
                            deviceId = did,
                            entity = "plan",
                            payload = buildJsonObject {
                                put("id", row.id)
                                put("householdId", row.householdId)
                                put(
                                    "date",
                                    Instant.ofEpochMilli(row.date).atZone(ZoneOffset.UTC).toLocalDate().toString(),
                                )
                                put("meal", row.mealRaw)
                                row.recipeId?.let { put("recipeId", it) }
                                put("note", row.note)
                                row.servings?.let { put("servings", it) }
                            },
                        ),
                    )
                }
                plans = db.plans().livePlans()
                refreshSnapshot()
                aggResult = "“${menu.name}” applied to week of $weekStart (${rows.size} entries)."
            }.onFailure {
                aggResult = "Couldn't apply “${menu.name}” (${it.message})."
            }
        }
    }

    fun addWeekToList(weekStart: LocalDate) {
        val db = container?.db ?: return
        scope.launch {
            runCatching {
                val now = System.currentTimeMillis()
                val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
                val days = (0..6).map { weekStart.plusDays(it.toLong()) }.toSet()
                val weekPlans = plans.filter { it.localDate() in days }
                val inputs = weekPlans.flatMap { plan ->
                    val recipe = plan.recipeId?.let { recipesById[it] }
                    val ings = plan.recipeId?.let { ingredientsByRecipe[it] }.orEmpty()
                    if (recipe != null && ings.isNotEmpty()) {
                        ings.map { ing ->
                            PlanGroceryInput(
                                name = ing.name,
                                quantity = ing.quantity,
                                unit = ing.unit,
                                baseServings = recipe.servings,
                                targetServings = plan.servings,
                                recipeId = recipe.id,
                            )
                        }
                    } else {
                        // Blank plan shells (no note and no resolvable recipe
                        // title) are skipped — falling back to mealRaw here
                        // created grocery lines literally named "dinner".
                        val recipeTitle = plan.recipeId?.let { recipesById[it]?.title }.orEmpty()
                        val name = plan.note.ifBlank { recipeTitle }
                        if (name.isBlank()) {
                            emptyList()
                        } else {
                            listOf(
                                PlanGroceryInput(
                                    name = name,
                                    quantity = null,
                                    unit = "",
                                    baseServings = 4.0,
                                    targetServings = plan.servings,
                                    recipeId = plan.recipeId,
                                ),
                            )
                        }
                    }
                }
                val lines = aggregateWeekToList(inputs)
                if (lines.isEmpty()) {
                    aggResult = "Nothing planned this week."
                    return@launch
                }
                // Always target the list named "Weekly shop" (creating it when
                // absent) instead of the most-recently-updated list, so
                // multi-list households get deterministic results.
                val liveLists = db.shoppingLists().liveLists().filterNot { it.deleted }
                val list = liveLists.firstOrNull { it.name == "Weekly shop" }
                    ?: ShoppingListEntity(
                        id = UUID.randomUUID().toString(), householdId = "hh-demo",
                        name = "Weekly shop", updatedAt = now, deviceId = did,
                    ).also { db.shoppingLists().upsertAll(listOf(it)) }
                // Reconcile before inserting so repeated taps don't duplicate
                // lines (fresh UUIDs never match). Choice: insert-only-missing,
                // matched by lowercase name + provenance recipeId; quantities
                // are display strings ("1½ cup") so re-summing would require
                // fragile parsing. To re-scale a week, clear the list first.
                val existingKeys = db.listItems().forList(list.id)
                    .filterNot { it.deleted }
                    .map { it.name.lowercase() to it.recipeId }
                    .toSet()
                val fresh = lines.filterNot { (it.name.lowercase() to it.recipeIds.firstOrNull()) in existingKeys }
                if (fresh.isEmpty()) {
                    aggResult = "${list.name} is already up to date (${lines.size} line(s))."
                    return@launch
                }
                val items = fresh.map { line ->
                    ListItemEntity(
                        id = UUID.randomUUID().toString(),
                        listId = list.id,
                        name = line.name,
                        quantity = if (line.totalQuantity != null) {
                            "${fractionDisplayString(line.totalQuantity)} ${line.unit}".trim()
                        } else {
                            line.unit
                        },
                        checked = false,
                        recipeId = line.recipeIds.firstOrNull(),
                        updatedAt = now,
                        deviceId = did,
                    )
                }
                db.listItems().upsertAll(items)
                db.shoppingLists().upsertAll(listOf(list.copy(updatedAt = now)))
                val liveItems = db.listItems().forList(list.id).filterNot { it.deleted }
                container.syncEngine.enqueue(
                    SyncEnvelopeDto(
                        id = list.id,
                        updatedAt = Instant.ofEpochMilli(now).toString(),
                        deviceId = did,
                        entity = "list",
                        payload = buildJsonObject {
                            put("id", list.id)
                            put("householdId", list.householdId)
                            put("name", list.name)
                            put(
                                "items",
                                JsonArray(
                                    liveItems.map { item ->
                                        buildJsonObject {
                                            put("id", item.id)
                                            put("name", item.name)
                                            put("quantity", item.quantity)
                                            put("aisle", item.aisle)
                                            put("checked", item.checked)
                                            item.recipeId?.let { put("recipeId", it) }
                                        }
                                    },
                                ),
                            )
                        },
                    ),
                )
                refreshSnapshot()
                aggResult = "${fresh.size} line(s) saved to ${list.name}: ${fresh.joinToString { it.display }}"
            }.onFailure {
                aggResult = "Couldn't add week to list (${it.message})."
            }
        }
    }

    // Rendered calendar entries derive from Room `plans` (reactive to menu
    // applies / sync) instead of hard-coded demo entries.
    val entries: List<DemoPlanEntry> = plans.filterNot { it.deleted }.map { plan ->
        DemoPlanEntry(
            id = plan.id,
            date = plan.localDate(),
            meal = plan.mealRaw,
            recipeTitle = plan.recipeId?.let { recipesById[it]?.title },
            note = plan.note,
            servings = plan.servings,
        )
    }
    val demoMenus = remember {
        listOf(
            DemoMenu("m1", "Easy weeknights", 5),
            DemoMenu("m2", "Sunday batch", 3),
        )
    }
    val feedUrl = remember { planFeedSubscribeUrl("https://api.keepcooking.app", "household-1") }

    val weekStart = anchor.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    val spanTitle = when (span) {
        PlanSpan.DAY -> anchor.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
        PlanSpan.WEEK -> "Week of ${weekStart.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))}"
        PlanSpan.MONTH -> {
            val ym = YearMonth.from(anchor)
            "${ym.month.name.lowercase().replaceFirstChar { it.uppercase() }} ${ym.year}"
        }
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
                OutlinedButton(onClick = {
                    anchor = when (span) {
                        PlanSpan.MONTH -> YearMonth.from(anchor).minusMonths(1).atDay(1)
                        PlanSpan.WEEK -> anchor.minusWeeks(1)
                        PlanSpan.DAY -> anchor.minusDays(1)
                    }
                }) {
                    Text("‹")
                }
                Text(spanTitle, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                OutlinedButton(onClick = { anchor = LocalDate.now() }) { Text("Today") }
                OutlinedButton(onClick = {
                    anchor = when (span) {
                        PlanSpan.MONTH -> YearMonth.from(anchor).plusMonths(1).atDay(1)
                        PlanSpan.WEEK -> anchor.plusWeeks(1)
                        PlanSpan.DAY -> anchor.plusDays(1)
                    }
                }) {
                    Text("›")
                }
            }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = { addWeekToList(weekStart) },
                enabled = container != null,
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
                    val ym = YearMonth.from(anchor)
                    (1..ym.lengthOfMonth()).map { ym.atDay(it) }
                }
            }
            daysToShow.forEach { day ->
                val dayEntries = entriesFor(day)
                Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Column(Modifier.padding(12.dp)) {
                        Text(
                            day.format(DateTimeFormatter.ofPattern("EEE, MMM d")),
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

            if (menus.isNotEmpty() || demoMenus.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text("Reusable menus", style = MaterialTheme.typography.titleMedium)
                menus.forEach { menu ->
                    val count = menuEntriesOf(menu).size
                    Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(menu.name, style = MaterialTheme.typography.bodyLarge)
                                Text("$count entries", style = MaterialTheme.typography.labelSmall)
                            }
                            OutlinedButton(
                                onClick = { applyMenu(menu, weekStart) },
                                enabled = container != null && count > 0,
                            ) {
                                Text("Apply to week")
                            }
                        }
                    }
                }
                if (menus.isEmpty()) {
                    demoMenus.forEach { menu ->
                        Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(menu.name, style = MaterialTheme.typography.bodyLarge)
                                    Text("${menu.entryCount} entries", style = MaterialTheme.typography.labelSmall)
                                }
                                OutlinedButton(onClick = {}, enabled = false) {
                                    Text("Apply to week")
                                }
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
                        Spacer(Modifier.height(8.dp))
                        OutlinedButton(onClick = {
                            runCatching {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            }.onFailure {
                                aggResult = "No calendar app found to open the feed."
                            }
                        }) { Text("Open in Calendar") }
                    }
                }
            }
            Spacer(Modifier.height(56.dp))
        }
    }
}
