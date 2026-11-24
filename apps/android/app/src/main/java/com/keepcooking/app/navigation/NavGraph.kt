package com.keepcooking.app.navigation

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
import com.keepcooking.app.ui.screens.CookScreen
import com.keepcooking.app.ui.screens.ExportScreen
import com.keepcooking.app.ui.screens.IngestScreen
import com.keepcooking.app.ui.screens.LibraryRecipeRow
import com.keepcooking.app.ui.screens.LibraryScreen
import com.keepcooking.app.ui.screens.PlanScreen
import com.keepcooking.app.ui.screens.RecipeDetailScreen
import com.keepcooking.app.ui.screens.ShareScreen
import com.keepcooking.app.ui.screens.ShopScreen
import com.keepcooking.app.wear.NowCookingScreen

/** App nav graph. Views never touch the network directly — they call SyncEngine via ViewModels. */
@Composable
fun KeepCookingNav() {
    val navController = rememberNavController()
    val context = androidx.compose.ui.platform.LocalContext.current
    val container = remember(context) {
        (context.applicationContext as com.keepcooking.app.KeepCookingApp).container
    }
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
            startDestination = TopDestination.Library.route,
            modifier = Modifier.padding(padding),
        ) {
            composable(TopDestination.Library.route) {
                var rows by remember { mutableStateOf(listOf<LibraryRecipeRow>()) }
                LaunchedEffect(Unit) {
                    val live = container.db.recipes().liveRecipes()
                    rows = live.map { r ->
                        val ings = container.db.ingredients().forRecipe(r.id)
                        val steps = container.db.steps().forRecipe(r.id)
                        val cats = runCatching {
                            kotlinx.serialization.json.Json.decodeFromString<List<String>>(r.categoriesJson)
                        }.getOrDefault(emptyList())
                        LibraryRecipeRow(
                            recipeId = r.id,
                            title = r.title,
                            recipeDescription = r.recipeDescription,
                            servings = r.servings,
                            prepMinutes = r.prepMinutes,
                            cookMinutes = r.cookMinutes,
                            rating = r.rating,
                            source = r.source,
                            categories = cats,
                            ingredientNames = ings.map { it.name },
                            stepTexts = steps.map { it.text },
                            photoOriginal = r.photoOriginal,
                            photoThumb = r.photoThumb,
                        )
                    }
                }
                LibraryScreen(recipes = rows, onRecipeClick = { id ->
                    navController.navigate(Routes.recipeDetail(id))
                })
            }
            composable(TopDestination.Ingest.route) { IngestScreen() }
            composable(TopDestination.Cook.route) { CookScreen() }
            composable(TopDestination.Plan.route) { PlanScreen() }
            composable(TopDestination.Shop.route) { ShopScreen() }
            composable(
                route = Routes.RecipeDetail,
                arguments = listOf(navArgument("recipeId") { type = NavType.StringType }),
            ) { entry ->
                RecipeDetailScreen(
                    recipeId = entry.arguments?.getString("recipeId").orEmpty(),
                    onBack = { navController.popBackStack() },
                )
            }
            composable(Routes.Export) { ExportScreen(container) }
            composable(Routes.Share) { ShareScreen(container) }
            composable(Routes.NowCooking) { NowCookingScreen() }
        }
    }
}
