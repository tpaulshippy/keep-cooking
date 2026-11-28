package com.keepcooking.app.ui.screens

import com.keepcooking.app.AppContainer
import java.util.concurrent.ConcurrentHashMap

/**
 * Single seam for turning a stored recipe photo key into something Coil can
 * load. Absolute http(s), content/file/android.resource and data: URIs pass
 * through untouched. Bare R2 storage keys (e.g. `photos/<sha>.jpg`, as seeded
 * and synced) resolve to null here — see [resolveRecipePhoto] for the signed
 * variant. Callers render their placeholder when resolution returns null.
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

/** Signed-URL cache: one GET /photos/sign per R2 key per process lifetime
 * (server URLs expire in <15min; entries may go stale after that, in which
 * case Coil fails and callers fall back to their placeholder). */
private val signedPhotoUrlCache = ConcurrentHashMap<String, String>()

/**
 * Full photo resolution for a stored key: absolute URIs pass through via
 * [resolvePhotoUrl], R2 storage keys are minted into short-lived signed
 * download URLs through GET /photos/sign (cached). Returns null when the key
 * is blank, the sign call fails (offline, unconfigured photo serving,
 * unknown key), or the response carries no URL — callers show a placeholder.
 */
suspend fun resolveRecipePhoto(container: AppContainer, key: String?): String? {
    val v = key?.trim().orEmpty()
    if (v.isEmpty()) return null
    resolvePhotoUrl(v)?.let { return it }
    signedPhotoUrlCache[v]?.let { return it }
    return runCatching {
        val signed = container.syncEngine.activeApi().signPhoto(v)
        signed.url.trim().takeIf { it.isNotEmpty() }?.also { signedPhotoUrlCache[v] = it }
    }.getOrNull()
}
