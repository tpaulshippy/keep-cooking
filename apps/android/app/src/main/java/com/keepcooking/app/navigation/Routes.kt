package com.keepcooking.app.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.ui.graphics.vector.ImageVector

/** Bottom-bar destinations. Parity with iOS PhoneTabView: Recipes / Plan / Lists / Library / More. */
enum class TopDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
) {
    Recipes("recipes", "Recipes", Icons.Filled.MenuBook),
    Plan("plan", "Plan", Icons.Filled.CalendarMonth),
    Lists("lists", "Lists", Icons.Filled.ShoppingCart),
    Library("library", "Library", Icons.Filled.Book),
    More("more", "More", Icons.Filled.MoreHoriz),
}

object Routes {
    const val RecipeDetail = "recipe/{recipeId}"
    fun recipeDetail(recipeId: String) = "recipe/$recipeId"
    /** Cook is a recipe-launched flow (parity with iOS), not a tab. */
    const val Cook = "cook/{recipeId}"
    fun cook(recipeId: String) = "cook/$recipeId"
    /** Ingest is launched from Recipes/More + the share sheet, not a tab. */
    const val Ingest = "ingest"
    const val Export = "export"
    const val Share = "share"
    const val NowCooking = "now_cooking"
}
