package com.keepcooking.app.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.SoupKitchen
import androidx.compose.ui.graphics.vector.ImageVector

/** Bottom-bar destinations. Parity with iOS tabs (Recipes/Library, Plan, Lists/Shop + Ingest, Cook). */
enum class TopDestination(
    val route: String,
    val label: String,
    val icon: ImageVector,
) {
    Library("library", "Library", Icons.Filled.Book),
    Ingest("ingest", "Ingest", Icons.Filled.AddCircle),
    Cook("cook", "Cook", Icons.Filled.SoupKitchen),
    Plan("plan", "Plan", Icons.Filled.CalendarMonth),
    Shop("shop", "Shop", Icons.Filled.ShoppingCart),
}

object Routes {
    const val RecipeDetail = "recipe/{recipeId}"
    fun recipeDetail(recipeId: String) = "recipe/$recipeId"
    const val Export = "export"
    const val Share = "share"
    const val NowCooking = "now_cooking"
}
