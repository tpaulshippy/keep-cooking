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

/** A minted signed URL plus its server expiry (millis since epoch). */
data class SignedPhoto(val url: String, val expiresAtMillis: Long)

/**
 * Expiry-aware signed-URL cache: one GET /photos/sign per R2 key until the
 * minted URL's expiry (server TTL <15min), then re-mint — entries never go
 * permanently stale. A 60s skew margin treats nearly-expired URLs as expired
 * so device-clock drift cannot serve a dead URL. Sign failures resolve to
 * null (callers show their placeholder); use [invalidate] to force the next
 * resolve to re-mint (e.g. from Coil's error path). Pure JVM-unit-testable
 * via the injected [sign] client and [nowMillis] clock.
 *
 * Lifetime: own one per screen via `remember` (matches web's per-page cache).
 */
class SignedPhotoCache(
    private val sign: suspend (String) -> SignedPhoto?,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val skewMarginMillis: Long = 60_000L,
) {
    private val entries = ConcurrentHashMap<String, SignedPhoto>()

    suspend fun resolve(key: String): String? {
        val now = nowMillis()
        entries[key]?.let { if (it.expiresAtMillis - skewMarginMillis > now) return it.url }
        val fresh = runCatching { sign(key) }.getOrNull()
        if (fresh != null && fresh.url.isNotBlank()) {
            entries[key] = fresh
            return fresh.url
        }
        return null
    }

    fun invalidate(key: String) {
        entries.remove(key.trim())
    }
}

private suspend fun containerPhotoSign(container: AppContainer, key: String): SignedPhoto? {
    val res = container.syncEngine.activeApi().signPhoto(key)
    val url = res.url.trim()
    if (url.isEmpty()) return null
    val exp = runCatching { java.time.Instant.parse(res.expiresAt).toEpochMilli() }.getOrDefault(0L)
    return SignedPhoto(url, exp)
}

/** Screen-scoped signed-URL cache backed by GET /photos/sign (own via `remember`). */
fun photoCacheFor(container: AppContainer): SignedPhotoCache =
    SignedPhotoCache(sign = { k -> containerPhotoSign(container, k) })

/**
 * Full photo resolution for a stored key: absolute URIs pass through via
 * [resolvePhotoUrl], R2 storage keys are minted into short-lived signed
 * download URLs through the screen [cache] (re-minted after expiry).
 * Returns null when the key is blank, the sign call fails (offline,
 * unconfigured photo serving, unknown key), or the response carries no URL —
 * callers show a placeholder.
 */
suspend fun resolveRecipePhoto(
    container: AppContainer,
    key: String?,
    cache: SignedPhotoCache,
): String? {
    val v = key?.trim().orEmpty()
    if (v.isEmpty()) return null
    resolvePhotoUrl(v)?.let { return it }
    return cache.resolve(v)
}

/** Drop a cached signed URL so the next resolve re-mints (Coil error path). */
fun invalidateSignedPhoto(key: String?, cache: SignedPhotoCache) {
    if (!key.isNullOrBlank()) cache.invalidate(key)
}
