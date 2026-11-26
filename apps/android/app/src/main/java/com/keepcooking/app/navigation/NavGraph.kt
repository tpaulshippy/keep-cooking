package com.keepcooking.app.navigation

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.keepcooking.app.AppContainer
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.StepEntity
import com.keepcooking.app.library.DuplicateMergePlan
import com.keepcooking.app.network.SyncEnvelopeDto
import com.keepcooking.app.share.ShareHandler
import com.keepcooking.app.ui.screens.CookScreen
import com.keepcooking.app.ui.screens.ExportScreen
import com.keepcooking.app.ui.screens.IngestDraft
import com.keepcooking.app.ui.screens.IngestScreen
import com.keepcooking.app.ui.screens.LibraryRecipeRow
import com.keepcooking.app.ui.screens.LibraryScreen
import com.keepcooking.app.ui.screens.MoreScreen
import com.keepcooking.app.ui.screens.PlanScreen
import com.keepcooking.app.ui.screens.RecipeDetailScreen
import com.keepcooking.app.ui.screens.RecipesScreen
import com.keepcooking.app.ui.screens.SettingsScreen
import com.keepcooking.app.ui.screens.loadLibraryRows
import com.keepcooking.app.ui.screens.ShareScreen
import com.keepcooking.app.ui.screens.ShopScreen
import com.keepcooking.app.wear.NowCookingScreen
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Persists an ingest draft to Room + sync outbox. */
private suspend fun saveIngestDraft(container: AppContainer, draft: IngestDraft) {
    val db = container.db
    val now = System.currentTimeMillis()
    val deviceId = container.syncEngine.deviceId()
    val id = UUID.randomUUID().toString()
    db.recipes().upsert(
        RecipeEntity(
            id = id,
            householdId = "hh-demo",
            title = draft.title,
            servings = 4.0,
            source = draft.source,
            sourceUrl = draft.sourceUrl,
            updatedAt = now,
            deviceId = deviceId,
        ),
    )
    // Stable child identities: each ingredient/step id is minted once and reused
    // in both the Room rows and the sync payload copies below.
    val ingredientRows = draft.ingredientLines.mapIndexed { i, line ->
        IngredientEntity(
            id = UUID.randomUUID().toString(),
            recipeId = id,
            name = line,
            display = line,
            position = i,
            updatedAt = now,
            deviceId = deviceId,
        )
    }
    db.ingredients().upsertAll(ingredientRows)
    val stepRows = draft.stepLines.mapIndexed { i, line ->
        StepEntity(
            id = UUID.randomUUID().toString(),
            recipeId = id,
            position = i,
            text = line,
            updatedAt = now,
            deviceId = deviceId,
        )
    }
    db.steps().upsertAll(stepRows)
    container.syncEngine.enqueue(
        SyncEnvelopeDto(
            id = id,
            updatedAt = Instant.ofEpochMilli(now).toString(),
            deviceId = deviceId,
            entity = "recipe",
            payload = buildJsonObject {
                put("id", id)
                put("householdId", "hh-demo")
                put("title", draft.title)
                put("source", draft.source)
                put("sourceUrl", draft.sourceUrl)
                put("servings", 4.0)
                put("categories", JsonArray(emptyList()))
                put(
                    "ingredients",
                    JsonArray(
                        ingredientRows.map { row ->
                            buildJsonObject {
                                put("id", row.id)
                                put("name", row.name)
                                put("display", row.display)
                                put("position", row.position)
                            }
                        },
                    ),
                )
                put(
                    "steps",
                    JsonArray(
                        stepRows.map { row ->
                            buildJsonObject {
                                put("id", row.id)
                                put("position", row.position)
                                put("text", row.text)
                            }
                        },
                    ),
                )
            },
        ),
    )
}

/** Applies a duplicate merge plan: unions into the survivor, tombstones losers. */
private suspend fun applyDuplicateMerge(
    container: AppContainer,
    plan: DuplicateMergePlan,
) {
    val db = container.db
    val now = System.currentTimeMillis()
    val deviceId = container.syncEngine.deviceId()
    val survivor = db.recipes().byId(plan.survivorId) ?: return
    val existingCats = runCatching {
        Json.parseToJsonElement(survivor.categoriesJson).jsonArray.map { it.jsonPrimitive.content }
    }.getOrDefault(emptyList())
    val mergedCats = (existingCats + plan.mergedCategories)
        .map { it.lowercase() }.toSortedSet().toList()
    db.recipes().upsert(
        survivor.copy(
            title = plan.survivorTitle,
            categoriesJson = JsonArray(mergedCats.map { JsonPrimitive(it) }).toString(),
            rating = plan.bestRating ?: survivor.rating,
            photoOriginal = plan.bestPhotoOriginal ?: survivor.photoOriginal,
            photoThumb = plan.bestPhotoThumb ?: survivor.photoThumb,
            updatedAt = now,
            deviceId = deviceId,
        ),
    )
    // Union ingredient display names into the survivor.
    val survivorIngredients = db.ingredients().forRecipe(plan.survivorId)
    val existing = survivorIngredients
        .map { it.name.lowercase().trim() }.toSet()
    val missing = plan.mergedIngredientNames.filter { it.lowercase().trim() !in existing }
    if (missing.isNotEmpty()) {
        val pos = (survivorIngredients.maxOfOrNull { it.position } ?: -1) + 1
        db.ingredients().upsertAll(
            missing.mapIndexed { i, name ->
                IngredientEntity(
                    id = UUID.randomUUID().toString(),
                    recipeId = plan.survivorId,
                    name = name,
                    display = name,
                    position = pos + i,
                    updatedAt = now,
                    deviceId = deviceId,
                )
            },
        )
    }
    // Union absorbed recipes' steps into the survivor (dedup by normalized text).
    // NavGraph owns the merge write, so the transfer lives here — not in the UI layer.
    val survivorSteps = db.steps().forRecipe(plan.survivorId)
    val seenStepTexts = survivorSteps.map { it.text.lowercase().trim() }.toMutableSet()
    var stepPos = (survivorSteps.maxOfOrNull { it.position } ?: -1) + 1
    val absorbedSteps = mutableListOf<StepEntity>()
    for (loserId in plan.absorbedIds) {
        for (step in db.steps().forRecipe(loserId)) {
            val key = step.text.lowercase().trim()
            if (key.isNotEmpty() && seenStepTexts.add(key)) {
                absorbedSteps.add(
                    StepEntity(
                        id = UUID.randomUUID().toString(),
                        recipeId = plan.survivorId,
                        position = stepPos++,
                        text = step.text,
                        updatedAt = now,
                        deviceId = deviceId,
                    ),
                )
            }
        }
    }
    if (absorbedSteps.isNotEmpty()) db.steps().upsertAll(absorbedSteps)
    // Tombstone the absorbed losers so sync converges.
    val mergedAtIso = Instant.ofEpochMilli(now).toString()
    for (loserId in plan.absorbedIds) {
        db.recipes().byId(loserId)?.let { loser ->
            db.recipes().upsert(loser.copy(deleted = true, updatedAt = now, deviceId = deviceId))
            container.syncEngine.enqueue(
                SyncEnvelopeDto(
                    id = loserId,
                    updatedAt = mergedAtIso,
                    deviceId = deviceId,
                    deleted = true,
                    entity = "recipe",
                    payload = buildJsonObject {
                        put("id", JsonPrimitive(loserId))
                        put("deleted", JsonPrimitive(true))
                    },
                ),
            )
        }
    }
    // Enqueue the full merged survivor envelope — loser tombstones alone leave
    // other devices without the merged title/categories/ingredients/steps.
    // Child ids are re-read from Room so payload copies match the rows exactly.
    val updatedSurvivor = db.recipes().byId(plan.survivorId) ?: return
    val finalIngredients = db.ingredients().forRecipe(plan.survivorId)
    val finalSteps = db.steps().forRecipe(plan.survivorId)
    val survivorCats = runCatching {
        Json.parseToJsonElement(updatedSurvivor.categoriesJson)
            .jsonArray.map { it.jsonPrimitive.content }
    }.getOrDefault(emptyList())
    container.syncEngine.enqueue(
        SyncEnvelopeDto(
            id = plan.survivorId,
            updatedAt = mergedAtIso,
            deviceId = deviceId,
            entity = "recipe",
            payload = buildJsonObject {
                put("id", plan.survivorId)
                put("householdId", updatedSurvivor.householdId)
                put("title", updatedSurvivor.title)
                put("recipeDescription", updatedSurvivor.recipeDescription)
                put("servings", updatedSurvivor.servings)
                updatedSurvivor.prepMinutes?.let { put("prepMinutes", it) }
                updatedSurvivor.cookMinutes?.let { put("cookMinutes", it) }
                updatedSurvivor.rating?.let { put("rating", it) }
                put("source", updatedSurvivor.source)
                put("sourceUrl", updatedSurvivor.sourceUrl)
                put("categories", JsonArray(survivorCats.map { JsonPrimitive(it) }))
                updatedSurvivor.photoOriginal?.let { put("photoOriginal", it) }
                updatedSurvivor.photoThumb?.let { put("photoThumb", it) }
                put(
                    "ingredients",
                    JsonArray(
                        finalIngredients.map { ing ->
                            buildJsonObject {
                                put("id", ing.id)
                                put("name", ing.name)
                                put("display", ing.display)
                                put("position", ing.position)
                            }
                        },
                    ),
                )
                put(
                    "steps",
                    JsonArray(
                        finalSteps.map { step ->
                            buildJsonObject {
                                put("id", step.id)
                                put("position", step.position)
                                put("text", step.text)
                            }
                        },
                    ),
                )
            },
        ),
    )
}

/** App nav graph. Views never touch the network directly — they call SyncEngine via ViewModels. */
@Composable
fun KeepCookingNav() {
    val navController = rememberNavController()
    val context = androidx.compose.ui.platform.LocalContext.current
    val container = remember(context) {
        (context.applicationContext as com.keepcooking.app.KeepCookingApp).container
    }
    val scope = rememberCoroutineScope()
    Scaffold(
        bottomBar = {
            NavigationBar {
                val backStack by navController.currentBackStackEntryAsState()
                val current = backStack?.destination
                TopDestination.entries.forEach { dest ->
                    NavigationBarItem(
                        selected = current?.hierarchy?.any { it.route == dest.route } == true,
                        onClick = {
                            navController.navigate(dest.route) {
                                popUpTo(navController.graph.findStartDestination().id) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(dest.icon, contentDescription = dest.label) },
                        label = { Text(dest.label) },
                    )
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = TopDestination.Recipes.route,
            modifier = Modifier.padding(padding),
        ) {
            composable(TopDestination.Recipes.route) {
                RecipesScreen(
                    container = container,
                    onRecipeClick = { id ->
                        navController.navigate(Routes.recipeDetail(id))
                    },
                    onAddRecipe = { navController.navigate(Routes.Ingest) },
                )
            }
            composable(TopDestination.Plan.route) { PlanScreen(container) }
            composable(TopDestination.Lists.route) { ShopScreen(container) }
            composable(TopDestination.Library.route) {
                var rows by remember { mutableStateOf(listOf<LibraryRecipeRow>()) }
                LaunchedEffect(Unit) { rows = loadLibraryRows(container) }
                LibraryScreen(
                    recipes = rows,
                    onRecipeClick = { id ->
                        navController.navigate(Routes.recipeDetail(id))
                    },
                    onMerge = { _, plan ->
                        scope.launch {
                            runCatching { applyDuplicateMerge(container, plan) }
                            // Refresh the survivor row from Room so the merged title,
                            // categories, ingredients, steps, rating and photos show
                            // immediately; drop the tombstoned losers.
                            rows = runCatching {
                                val updated = container.db.recipes().byId(plan.survivorId)
                                rows.mapNotNull { row ->
                                    when {
                                        row.recipeId in plan.absorbedIds -> null
                                        row.recipeId == plan.survivorId && updated != null -> {
                                            val ings = container.db.ingredients().forRecipe(row.recipeId)
                                            val steps = container.db.steps().forRecipe(row.recipeId)
                                            val cats = runCatching {
                                                Json.parseToJsonElement(updated.categoriesJson)
                                                    .jsonArray.map { it.jsonPrimitive.content }
                                            }.getOrDefault(row.categories)
                                            row.copy(
                                                title = updated.title,
                                                categories = cats,
                                                ingredientNames = ings.map { it.name },
                                                stepTexts = steps.map { it.text },
                                                rating = updated.rating ?: row.rating,
                                                photoOriginal = updated.photoOriginal,
                                                photoThumb = updated.photoThumb,
                                            )
                                        }
                                        else -> row
                                    }
                                }
                            }.getOrDefault(rows.filterNot { it.recipeId in plan.absorbedIds })
                        }
                    },
                )
            }
            composable(TopDestination.More.route) {
                MoreScreen(
                    onClip = { navController.navigate(Routes.Ingest) },
                    onExport = { navController.navigate(Routes.Export) },
                    onShare = { navController.navigate(Routes.Share) },
                    onNowCooking = { navController.navigate(Routes.NowCooking) },
                    onSettings = { navController.navigate(Routes.Settings) },
                )
            }
            // Ingest is a launched flow (Recipes + / More + share sheet), not a tab —
            // parity with iOS, where clipping lives in the recipe flow.
            composable(Routes.Ingest) {
                // Drain the pending-share queue + read the system clipboard so the
                // clipboard banner can surface a link to clip.
                var clipText by remember { mutableStateOf<String?>(null) }
                LaunchedEffect(Unit) {
                    clipText = ShareHandler.drainFirst(context)
                        ?: runCatching {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()
                        }.getOrNull()
                }
                IngestScreen(
                    clipboardText = clipText,
                    onSaveRecipe = { draft ->
                        // Room/outbox writes await here (called from a coroutine)
                        // so a failure surfaces in the Ingest UI instead of a
                        // premature "Saved".
                        runCatching { saveIngestDraft(container, draft) }
                            .fold(
                                onSuccess = { "Saved “${draft.title}”" },
                                onFailure = { e ->
                                    "Couldn't save “${draft.title}” " +
                                        "(${e.message ?: "unknown error"}). Try again."
                                },
                            )
                    },
                )
            }
            // Cook is a recipe-launched flow (parity with iOS CookModeView), not a tab.
            composable(
                route = Routes.Cook,
                arguments = listOf(navArgument("recipeId") { type = NavType.StringType }),
            ) { entry ->
                CookScreen(
                    recipeId = entry.arguments?.getString("recipeId").orEmpty(),
                    container = container,
                    onExit = { navController.popBackStack() },
                )
            }
            composable(
                route = Routes.RecipeDetail,
                arguments = listOf(navArgument("recipeId") { type = NavType.StringType }),
            ) { entry ->
                RecipeDetailScreen(
                    container = container,
                    recipeId = entry.arguments?.getString("recipeId").orEmpty(),
                    onBack = { navController.popBackStack() },
                    onCook = { id -> navController.navigate(Routes.cook(id)) },
                )
            }
            composable(Routes.Export) { ExportScreen(container) }
            composable(Routes.Share) { ShareScreen(container) }
            composable(Routes.Settings) {
                SettingsScreen(container, onBack = { navController.popBackStack() })
            }
            composable(Routes.NowCooking) { NowCookingScreen() }
        }
    }
}
