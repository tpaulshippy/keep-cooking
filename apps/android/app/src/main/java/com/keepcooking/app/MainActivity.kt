package com.keepcooking.app

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.keepcooking.app.navigation.KeepCookingNav
import com.keepcooking.app.share.ShareHandler
import com.keepcooking.app.shortcuts.AppShortcuts
import com.keepcooking.app.ui.theme.KeepCookingTheme
import com.keepcooking.app.widgets.SnapshotWriter
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Single-activity shell. Parity with iOS AdaptiveShell/PhoneTabView:
 * bottom NavigationBar with the 5 tabs (Library / Ingest / Cook / Plan / Shop).
 * Also owns ACTION_SEND clip intake (parity with ShareExtension) and app-
 * shortcut dispatch (parity with KeepCookingIntents).
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as KeepCookingApp).container
        container.seedIfNeeded()
        // Only handle the launch intent once — rotation recreates the activity
        // with the same intent, which must not re-enqueue shortcut work.
        if (savedInstanceState == null) {
            val shortcutWork = handleIncoming(intent)
            // Refresh the widget/watch snapshot only AFTER shortcut work completes,
            // so an ADD_TO_LIST shortcut's Room write is visible to the widget.
            lifecycleScope.launch {
                runCatching { shortcutWork?.join() }
                runCatching { SnapshotWriter.refresh(this@MainActivity, container.db) }
            }
        } else {
            lifecycleScope.launch {
                runCatching { SnapshotWriter.refresh(this@MainActivity, container.db) }
            }
        }
        setContent {
            KeepCookingTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    KeepCookingNav()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncoming(intent)
    }

    private fun handleIncoming(intent: Intent?): Job? {
        if (intent == null) return null
        // 1. Shared URL/text → pending clip intake for Ingest/Clip.
        ShareHandler.extractFrom(intent)?.let { ShareHandler.enqueue(this, it) }
        // 2. App shortcut actions → Room writes (offline; sync picks them up).
        val action = intent.action
        if (action in setOf(
                AppShortcuts.ACTION_ADD_RECIPE, AppShortcuts.ACTION_START_TIMER,
                AppShortcuts.ACTION_ADD_TO_LIST, AppShortcuts.ACTION_NEXT_STEP,
                AppShortcuts.ACTION_PREV_STEP,
            )
        ) {
            val container = (application as KeepCookingApp).container
            val extras = mapOf(
                AppShortcuts.EXTRA_TITLE to intent.getStringExtra(AppShortcuts.EXTRA_TITLE),
                AppShortcuts.EXTRA_INGREDIENTS to intent.getStringExtra(AppShortcuts.EXTRA_INGREDIENTS),
                AppShortcuts.EXTRA_MINUTES to intent.getIntExtra(AppShortcuts.EXTRA_MINUTES, 0)
                    .takeIf { intent.hasExtra(AppShortcuts.EXTRA_MINUTES) },
                AppShortcuts.EXTRA_LABEL to intent.getStringExtra(AppShortcuts.EXTRA_LABEL),
                AppShortcuts.EXTRA_ITEM to intent.getStringExtra(AppShortcuts.EXTRA_ITEM),
                AppShortcuts.EXTRA_QUANTITY to intent.getStringExtra(AppShortcuts.EXTRA_QUANTITY),
            )
            return lifecycleScope.launch {
                val deviceId = container.syncEngine.deviceId()
                val message = AppShortcuts.handleShortcutAction(
                    this@MainActivity, container.db, deviceId, action, extras,
                )
                message?.let { Toast.makeText(this@MainActivity, it, Toast.LENGTH_LONG).show() }
            }
        }
        return null
    }
}
