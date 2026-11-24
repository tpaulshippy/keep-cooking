package com.keepcooking.app.share

import android.content.Context
import android.content.Intent
import java.util.UUID

/**
 * Share intake — parity with iOS ShareExtension/ShareStore.swift.
 *
 * Android side: [MainActivity] declares an ACTION_SEND intent-filter; the
 * host app routes the incoming URL/text here. Pending URLs are held in
 * SharedPreferences (same role as the iOS App Group key
 * `smidgen.pendingShareURLs`); Ingest/Clip drains them on foreground.
 */
object ShareHandler {
    const val PREFS = "keepcooking_share"
    const val PENDING_KEY = "smidgen.pendingShareURLs"

    private val urlPattern = Regex("""https?://[^\s]+""")

    fun firstUrlIn(text: String): String? = urlPattern.find(text)?.value

    /** Extract a shareable URL/text from an incoming intent (null when nothing to clip). */
    fun extractFrom(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_VIEW) return null
        intent.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)?.let { return it.toString() }
        intent.dataString?.takeUnless { it.isBlank() }?.let { return it }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.getStringExtra(Intent.EXTRA_SUBJECT)
            ?: return null
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        return firstUrlIn(trimmed) ?: trimmed
    }

    /** Append a shared URL (extension/share-sheet side). No-ops on blank input. */
    fun enqueue(context: Context, url: String) {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val current = prefs.getStringSet(PENDING_KEY, emptySet())!!.toMutableSet()
        if (current.add(trimmed)) {
            prefs.edit().putStringSet(PENDING_KEY, current).apply()
        }
    }

    /** Read + clear pending URLs (host-app side). */
    fun drain(context: Context): List<String> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = prefs.getStringSet(PENDING_KEY, emptySet())!!.toList()
        prefs.edit().remove(PENDING_KEY).apply()
        return arr
    }

    fun pending(context: Context): List<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(PENDING_KEY, emptySet())!!.toList()
}

// MARK: - Household invites + cookbook share links (parity with iOS ShareViews.swift)

data class HouseholdInvite(
    val id: String = UUID.randomUUID().toString(),
    val householdId: String,
    val code: String = UUID.randomUUID().toString().take(8).uppercase(),
    val maxUses: Int = 5,
    val useCount: Int = 0,
    val expiresAtMillis: Long = System.currentTimeMillis() + 7 * 24 * 60 * 60 * 1000L,
) {
    val isExpired: Boolean get() = System.currentTimeMillis() > expiresAtMillis
    val inviteUrl: String get() = "https://keep.cooking/invite/$householdId/$code"

    companion object {
        fun make(householdId: String): HouseholdInvite = HouseholdInvite(householdId = householdId)
    }
}
