package com.keepcooking.app

import com.keepcooking.app.network.ApiService
import com.keepcooking.app.network.SyncEnvelopeDto
import com.keepcooking.app.sync.SyncCryptoException
import com.keepcooking.app.sync.canonicalE2EMillis
import com.keepcooking.app.sync.categoriesJsonOf
import com.keepcooking.app.sync.e2eHeaderAD
import com.keepcooking.app.sync.foldEnvelopesForE2E
import com.keepcooking.app.sync.isFoldedShell
import com.keepcooking.app.sync.kid
import com.keepcooking.app.sync.open
import com.keepcooking.app.sync.outboxIdsSuperseded
import com.keepcooking.app.sync.pullCursorMax
import com.keepcooking.app.sync.remoteWins
import com.keepcooking.app.sync.seal
import com.keepcooking.app.sync.shellChildDeleted
import com.keepcooking.app.sync.shellChildStamp
import com.keepcooking.app.sync.shellChildWriteStamp
import com.keepcooking.app.sync.SyncInviteBundle
import java.time.Instant
import javax.crypto.spec.SecretKeySpec
import kotlin.coroutines.Continuation
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Parity-fix regression tests (cubic P1/P2): bare wire shapes, LWW-after-tombstone, shells, reconcile, cursor, crypto. */
class SyncParityFixesTest {

    private val testJson = Json { ignoreUnknownKeys = true }

    private fun env(
        entity: String,
        id: String,
        updatedAt: String,
        deviceId: String = "d1",
        deleted: Boolean = false,
        payload: kotlinx.serialization.json.JsonObject = buildJsonObject { put("id", id) },
    ) = SyncEnvelopeDto(
        id = id, updatedAt = updatedAt, deviceId = deviceId,
        deleted = deleted, entity = entity, payload = payload,
    )

    private fun iso(millis: Long): String = Instant.ofEpochMilli(millis).toString()

    // --- 1/2. Bare-array push/pull shapes (contract: openapi /sync/push + /sync/pull) ---

    @Test
    fun `push takes a bare list body`() {
        val m = ApiService::class.java.getMethod(
            "push", String::class.java, List::class.java, Continuation::class.java,
        )
        assertEquals(List::class.java, m.parameterTypes[1])
    }

    @Test
    fun `pull takes since and householdId and returns a list`() {
        val m = ApiService::class.java.getMethod(
            "pull",
            String::class.java, String::class.java, String::class.java, Continuation::class.java,
        )
        assertEquals(4, m.parameterTypes.size)
        assertEquals(String::class.java, m.parameterTypes[1])
        assertEquals(String::class.java, m.parameterTypes[2])
        // Suspend functions erase the return to Object; the List<SyncEnvelopeDto>
        // return is enforced at compile time by SyncEngine's `val remote: List<...>` use.
    }

    @Test
    fun `v1 envelope wrapper types are gone`() {
        for (name in listOf("PushRequest", "PushResponse", "PullResponse")) {
            assertThrows(ClassNotFoundException::class.java) {
                Class.forName("com.keepcooking.app.network.$name")
            }
        }
    }

    @Test
    fun `envelope lists encode as bare json arrays`() {
        val list = listOf(env("recipe", "r1", "2024-01-01T00:00:00Z"))
        val encoded = testJson.encodeToString(list)
        val parsed = Json.parseToJsonElement(encoded)
        assertTrue(parsed is JsonArray)
        assertEquals(1, parsed.jsonArray.size)
    }

    // --- 3. LWW after tombstones (lists/pantry/plan/menu compare incl. deletes) ---

    @Test
    fun `older remote live does not beat newer tombstone`() {
        assertFalse(remoteWins(localUpdatedAt = 200L, remoteUpdatedAt = 100L))
    }

    @Test
    fun `newer remote tombstone beats older live row`() {
        assertTrue(remoteWins(localUpdatedAt = 100L, remoteUpdatedAt = 200L))
    }

    @Test
    fun `equal timestamps take remote for idempotent convergence`() {
        assertTrue(remoteWins(localUpdatedAt = 100L, remoteUpdatedAt = 100L))
    }

    @Test
    fun `unknown row always takes remote`() {
        assertTrue(remoteWins(localUpdatedAt = null, remoteUpdatedAt = 100L))
    }

    // --- 5. Outbox reconcile against pulled winners ---

    @Test
    fun `matching pending row is superseded by equal winner`() {
        val pending = listOf(env("recipe", "r1", "2024-01-01T00:00:00Z"))
        val winners = listOf(env("recipe", "r1", "2024-01-01T00:00:00Z", deviceId = "d2"))
        assertEquals(setOf("recipe:r1"), outboxIdsSuperseded(pending, winners))
    }

    @Test
    fun `older pending row is superseded by newer winner`() {
        val pending = listOf(env("list", "l1", "2024-01-01T00:00:00Z"))
        val winners = listOf(env("list", "l1", "2024-02-01T00:00:00Z"))
        assertEquals(setOf("list:l1"), outboxIdsSuperseded(pending, winners))
    }

    @Test
    fun `newer pending edit survives older winner`() {
        val pending = listOf(env("pantryItem", "p1", "2024-02-01T00:00:00Z"))
        val winners = listOf(env("pantryItem", "p1", "2024-01-01T00:00:00Z"))
        assertTrue(outboxIdsSuperseded(pending, winners).isEmpty())
    }

    @Test
    fun `unrelated ids never reconcile`() {
        val pending = listOf(env("menu", "m1", "2024-01-01T00:00:00Z"))
        val winners = listOf(env("menu", "m2", "2024-03-01T00:00:00Z"))
        assertTrue(outboxIdsSuperseded(pending, winners).isEmpty())
    }

    // --- 6. Cursor advances from max envelope timestamp ---

    @Test
    fun `cursor is the max envelope timestamp`() {
        val remote = listOf(
            env("recipe", "r1", "2024-01-03T00:00:00Z"),
            env("recipe", "r2", "2024-01-01T00:00:00Z"),
            env("recipe", "r3", "2024-01-02T00:00:00Z"),
        )
        assertEquals(Instant.parse("2024-01-03T00:00:00Z"), pullCursorMax(remote))
    }

    @Test
    fun `cursor ignores unparseable timestamps and empties`() {
        assertNull(pullCursorMax(emptyList()))
        val remote = listOf(env("recipe", "r1", "not-a-timestamp"))
        assertNull(pullCursorMax(remote))
        val mixed = listOf(
            env("recipe", "r1", "garbage"),
            env("recipe", "r2", "2024-05-01T00:00:00Z"),
        )
        assertEquals(Instant.parse("2024-05-01T00:00:00Z"), pullCursorMax(mixed))
    }

    // --- 4. Sparse shells preserve the parent snapshot ---

    @Test
    fun `folded shell is detected`() {
        val shell = env(
            "recipe", "r1", "2024-01-01T00:00:00Z",
            payload = buildJsonObject { put("_foldedShell", true) },
        )
        assertTrue(isFoldedShell(shell))
        assertFalse(isFoldedShell(env("recipe", "r1", "2024-01-01T00:00:00Z")))
    }

    @Test
    fun `deleted markers never write`() {
        val marker = buildJsonObject {
            put("id", "c1")
            put("deleted", true)
            put("updatedAt", 300L)
        }
        assertTrue(shellChildDeleted(marker))
        assertNull(shellChildWriteStamp(marker, existingUpdatedAt = 100L, remoteTs = 400L))
        assertNull(shellChildWriteStamp(marker, existingUpdatedAt = null, remoteTs = 400L))
    }

    @Test
    fun `new shell child stamps its own millis not the header`() {
        val entry = buildJsonObject {
            put("id", "c1")
            put("updatedAt", 150L)
        }
        assertFalse(shellChildDeleted(entry))
        assertEquals(150L, shellChildStamp(entry))
        assertEquals(150L, shellChildWriteStamp(entry, existingUpdatedAt = null, remoteTs = 999L))
    }

    @Test
    fun `unstamped new child falls back to header time`() {
        val entry = buildJsonObject { put("id", "c1") }
        assertEquals(Long.MIN_VALUE, shellChildStamp(entry))
        assertEquals(999L, shellChildWriteStamp(entry, existingUpdatedAt = null, remoteTs = 999L))
        // ...but an unstamped incoming entry never clobbers a stamped local row.
        assertNull(shellChildWriteStamp(entry, existingUpdatedAt = 100L, remoteTs = 999L))
    }

    @Test
    fun `shell child replace follows per-child LWW`() {
        val entry = buildJsonObject {
            put("id", "c1")
            put("updatedAt", 150L)
        }
        assertEquals(150L, shellChildWriteStamp(entry, existingUpdatedAt = 100L, remoteTs = 200L))
        assertEquals(150L, shellChildWriteStamp(entry, existingUpdatedAt = 150L, remoteTs = 200L))
        assertNull(shellChildWriteStamp(entry, existingUpdatedAt = 151L, remoteTs = 200L))
    }

    // --- 7. Tombstones fold by absence only when they win child LWW ---

    private fun parentWithChild(parentTs: Long, childStamp: Long): SyncEnvelopeDto {
        val pid = "r1"
        return env(
            "recipe", pid, iso(parentTs),
            payload = buildJsonObject {
                put("id", pid)
                put(
                    "ingredients",
                    JsonArray(
                        listOf(
                            buildJsonObject {
                                put("id", "c1")
                                put("name", "Flour")
                                put("updatedAt", childStamp)
                                put("deviceId", "d1")
                            },
                        ),
                    ),
                )
            },
        )
    }

    private fun tombstone(parentId: String, childTs: Long): SyncEnvelopeDto =
        env(
            "ingredient", "c1", iso(childTs), deleted = true,
            payload = buildJsonObject {
                put("id", "c1")
                put("recipeId", parentId)
            },
        )

    @Test
    fun `stale tombstone does not remove newer embedded child`() {
        val parentTs = 1_700_000_000_000L
        val folded = foldEnvelopesForE2E(
            listOf(parentWithChild(parentTs, childStamp = parentTs), tombstone("r1", parentTs - 1_000L)),
        )
        assertEquals(1, folded.size)
        val ings = folded.single().payload["ingredients"]!!.jsonArray
        assertEquals(1, ings.size)
        assertEquals("c1", ings[0].jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals(iso(parentTs), folded.single().updatedAt)
    }

    @Test
    fun `winning tombstone removes embedded child and bumps parent`() {
        val parentTs = 1_700_000_000_000L
        val childTs = parentTs + 1_000L
        val folded = foldEnvelopesForE2E(
            listOf(parentWithChild(parentTs, childStamp = parentTs), tombstone("r1", childTs)),
        )
        assertEquals(1, folded.size)
        assertTrue(folded.single().payload["ingredients"]!!.jsonArray.isEmpty())
        assertEquals(iso(childTs), folded.single().updatedAt)
    }

    @Test
    fun `older live child does not clobber newer embedded entry`() {
        val parentTs = 1_700_000_000_000L
        val live = env(
            "ingredient", "c1", iso(parentTs - 5_000L),
            payload = buildJsonObject {
                put("id", "c1")
                put("recipeId", "r1")
                put("name", "Stale")
            },
        )
        val folded = foldEnvelopesForE2E(listOf(parentWithChild(parentTs, childStamp = parentTs), live))
        val entry = folded.single().payload["ingredients"]!!.jsonArray.single().jsonObject
        assertEquals("Flour", entry["name"]!!.jsonPrimitive.content)
        assertEquals(iso(parentTs), folded.single().updatedAt)
    }

    // --- 8. categories default to [] ---

    @Test
    fun `categories default to empty array`() {
        assertEquals("[]", categoriesJsonOf(buildJsonObject { put("id", "r1") }))
        assertEquals("[]", categoriesJsonOf(buildJsonObject { put("categories", JsonNull) }))
        val withCats = buildJsonObject {
            put("categories", JsonArray(listOf(JsonPrimitive("a"), JsonPrimitive("b"))))
        }
        assertEquals("[\"a\",\"b\"]", categoriesJsonOf(withCats))
    }

    // --- 9. Invite verify requires matching kid ---

    @Test
    fun `consistent bundle verifies`() {
        val code = "correct horse battery staple"
        val bundle = SyncInviteBundle.make(householdId = "hh1", syncCode = code, kid = kid(code))
        assertTrue(bundle.verify())
    }

    @Test
    fun `mismatched kid fails verification`() {
        val bundle = SyncInviteBundle.make(householdId = "hh1", syncCode = "code-a", kid = kid("code-a"))
        assertFalse(bundle.copy(kid = kid("code-b")).verify())
    }

    @Test
    fun `mismatched hash fails verification`() {
        val code = "code-a"
        val bundle = SyncInviteBundle.make(householdId = "hh1", syncCode = code, kid = kid(code))
        assertFalse(bundle.copy(hash = "0".repeat(64)).verify())
    }

    // --- 10. Header AD is real JSON (quotes/backslashes round-trip) ---

    @Test
    fun `header AD round-trips hostile device ids`() {
        val tricky = "dev\"ice\\quo\"te\\\\tail"
        val ad = e2eHeaderAD(
            v = 2, alg = "AES-GCM-256", kid = "k1", householdHash = "h",
            id = "r1", updatedAtMillis = 1_700_000_000_123L, deviceId = tricky,
            deleted = false, entity = "recipe",
        )
        val parts = Json.parseToJsonElement(ad.toString(Charsets.UTF_8)).jsonArray
        assertEquals(10, parts.size)
        assertEquals(tricky, parts[7].jsonPrimitive.content)
        // Canonical millis are floored to whole seconds*1000 (whole millis here).
        assertEquals(canonicalE2EMillis(1_700_000_000_123L).toString(), parts[6].jsonPrimitive.content)
    }

    @Test
    fun `header AD encoding is deterministic`() {
        fun ad() = e2eHeaderAD(
            v = 2, alg = "AES-GCM-256", kid = "k\"1", householdHash = "h",
            id = "r1", updatedAtMillis = 999L, deviceId = "d\\1",
            deleted = true, entity = "plan",
        )
        assertArrayEquals(ad(), ad())
    }

    // --- Seal/open round-trip (java.util Base64: JVM-safe) ---

    @Test
    fun `seal open round-trips under bound AD`() {
        val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        val ad = "bind-me".toByteArray(Charsets.UTF_8)
        val (nonce, ct) = seal("hello sync".toByteArray(Charsets.UTF_8), key, ad)
        assertArrayEquals("hello sync".toByteArray(Charsets.UTF_8), open(nonce, ct, key, ad))
        assertThrows(SyncCryptoException.OpenFailed::class.java) {
            open(nonce, ct, key, "tampered".toByteArray(Charsets.UTF_8))
        }
    }
}
