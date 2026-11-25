package com.keepcooking.app.ui.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

// Keep Cooking palette — warm kitchen neutrals, parity with iOS theme.
val Tomato = Color(0xFFC2410C)
val TomatoDark = Color(0xFF9A3412)
val Basil = Color(0xFF15803D)
val Cream = Color(0xFFFFFBEB)
val Charcoal = Color(0xFF1C1917)

val LightColors = lightColorScheme(
    primary = Tomato,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFEDD5),
    onPrimaryContainer = Color(0xFF7C2D12),
    secondary = Basil,
    background = Cream,
    surface = Color.White,
    onBackground = Charcoal,
    onSurface = Charcoal,
)

val DarkColors = darkColorScheme(
    primary = Color(0xFFFB923C),
    onPrimary = Color(0xFF431407),
    secondary = Color(0xFF4ADE80),
    background = Color(0xFF1C1917),
    surface = Color(0xFF292524),
    onBackground = Color(0xFFF5F5F4),
    onSurface = Color(0xFFF5F5F4),
)
