package com.keepcooking.app

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.keepcooking.app.ui.theme.KeepCookingTheme
import com.keepcooking.app.ui.screens.LibraryScreen
import org.junit.Rule
import org.junit.Test

/** Compose UI test — Library tab renders offline placeholder. */
class LibraryScreenTest {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun libraryShowsPlaceholder() {
        composeRule.setContent {
            KeepCookingTheme { LibraryScreen() }
        }
        composeRule.onNodeWithText("Library").assertExists()
    }
}
