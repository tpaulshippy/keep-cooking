package com.keepcooking.app.ui.screens

/**
 * Single seam for turning a stored recipe photo key into something Coil can
 * load. Absolute http(s), content/file/android.resource and data: URIs pass
 * through untouched. Bare R2 storage keys (e.g. `photos/<sha>.jpg`, as seeded
 * and synced) resolve to null: the app has no GET /photos/sign client yet
 * (openapi `photoDownload` requires exp/sig query params), so callers render
 * their placeholder instead of attempting a broken relative load.
 * TODO: mint signed URLs via /photos/sign and return them here.
 */
fun resolvePhotoUrl(key: String?): String? {
    val v = key?.trim().orEmpty()
    if (v.isEmpty()) return null
    val lower = v.lowercase()
    if (lower.startsWith("http://") || lower.startsWith("https://") ||
        lower.startsWith("content://") || lower.startsWith("file://") ||
        lower.startsWith("android.resource://") || lower.startsWith("data:")
    ) {
        return v
    }
    return null
}
