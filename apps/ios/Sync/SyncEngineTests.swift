// Keep Cooking — Lane 2 iOS Foundation
// apps/ios/Sync/SyncEngineTests.swift
//
// XCTest coverage for the pure sync core:
//   1. Two-device convergence (A + B edit offline, sync, agree).
//   2. Collision matrix (rows x columns documented in SYNC_TEST.md).
//   3. Photo SHA-256 dedup.
//
// These tests exercise ONLY pure Sendable functions + the SyncEngine actor
// with an in-memory fake transport — no SwiftData, no network, no CloudKit.

import XCTest
import CryptoKit
import Foundation

// MARK: - Fake transport (in-memory Lane 1 stand-in)

actor FakeServer {
    var store: [String: SyncEnvelope] = [:]

    func pull(since: Date?) async -> [SyncEnvelope] {
        store.values.filter { env in
            guard let since else { return true }
            return env.updatedAt > since
        }.sorted(by: { $0.updatedAt < $1.updatedAt })
    }

    /// LWW accept: server keeps the newest per id, returns server-won conflicts.
    func push(_ envs: [SyncEnvelope]) async -> [SyncEnvelope] {
        var won: [SyncEnvelope] = []
        for env in envs {
            if let cur = store[env.id], cur.updatedAt > env.updatedAt {
                won.append(cur)
            } else {
                store[env.id] = env
            }
        }
        return won
    }
}

struct FakeTransport: SyncTransport {
    let server: FakeServer
    func pull(since: Date?) async throws -> [SyncEnvelope] {
        await server.pull(since: since)
    }
    func push(_ envelopes: [SyncEnvelope]) async throws -> [SyncEnvelope] {
        await server.push(envelopes)
    }
}

// MARK: - Helpers

/// Sendable box so @Sendable applyRemote closures can record results
/// without captured-var warnings (error in Swift 6 mode).
/// Unchecked because all access is serialized through `lock`.
final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SyncEnvelope] = []
    func append(_ envelope: SyncEnvelope) {
        lock.withLock { values.append(envelope) }
    }
    var all: [SyncEnvelope] {
        lock.withLock { values }
    }
}

func makeEnv(id: String, at date: Date, device: String, deleted: Bool = false,
             entity: SyncEntityName = .recipe) -> SyncEnvelope {
    SyncEnvelope(id: id, updatedAt: date, deviceId: device, deleted: deleted,
                 entity: entity, payload: ["title": "T"])
}

let base = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - 4. E2E fold (ingredient/step -> parent recipe)

/// In-memory /v2 stand-in: newest-wins per id (ties keep stored, mirroring
/// production `e2eIsNewer`), `{stored}` push shape, strict `updatedAt > since`
/// pull filter on ISO strings. The store is PARTITIONED by household bucket
/// hash like production (`PUT/GET /v2/sync/:hash` routes to an isolated
/// bucket): a single shared store cannot catch cross-household routing
/// regressions. Push additionally mirrors the production PUT validations
/// (`householdHash` bucket match, UUID ids) — violations fail the test and
/// are never stored.
actor FakeE2EServer {
    /// hash -> id -> envelope.
    var store: [String: [String: EncryptedEnvelope]] = [:]
    var pullSinceBounds: [Date?] = []
    /// Ids refused for schema violations (bucket mismatch / non-UUID).
    var rejectedPushes: [String] = []
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        // Millis precision, mirroring the production /v2 wire: fixed-width
        // fractions keep lexical order == parsed order.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func pullEncrypted(hash: String, since: Date?) async -> [EncryptedEnvelope] {
        pullSinceBounds.append(since)
        let bound = since.map { iso.string(from: $0) } ?? "1970-01-01T00:00:00.000Z"
        return (store[hash] ?? [:]).values
            .filter { iso.string(from: $0.updatedAt) > bound }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id < $1.id
            }
    }

    func pushEncrypted(hash: String, _ envs: [EncryptedEnvelope]) async -> [String] {
        var stored: [String] = []
        for env in envs {
            guard env.householdHash == hash else {
                // Cross-bucket pushes are rejected, never stored. No XCTFail
                // here: testBucketsAreIsolatedByHash deliberately exercises
                // this path and asserts on the return value + rejectedPushes.
                rejectedPushes.append(env.id)
                continue
            }
            guard UUID(uuidString: env.id) != nil else {
                rejectedPushes.append(env.id)
                XCTFail("non-UUID id rejected by the production envelope schema: \(env.id)")
                continue
            }
            if let cur = store[hash]?[env.id], cur.updatedAt >= env.updatedAt { continue }
            if store[hash] == nil { store[hash] = [:] }
            store[hash]![env.id] = env
            stored.append(env.id)
        }
        return stored
    }
}

struct FakeE2ETransport: E2EEncryptedTransport {
    let server: FakeE2EServer
    let hash: String
    func pullEncrypted(hash: String, since: Date?) async throws -> [EncryptedEnvelope] {
        await server.pullEncrypted(hash: hash, since: since)
    }
    func pushEncrypted(hash: String, _ envelopes: [EncryptedEnvelope]) async throws -> [String] {
        await server.pushEncrypted(hash: hash, envelopes)
    }
}

func makeE2EIdentity() -> E2ESyncIdentity {
    E2ESyncIdentity(syncCode: "test-code-1234567890", householdId: "hh-test", kid: "testkid0001")
}

// Production v2 PUT 400s non-UUID ids (`id: z.string().uuid()` in
// api/src/e2e.ts), so every E2E fixture id — including folded
// parent/recipeId links — is a UUID.
private let e2eR1 = "11111111-1111-4111-8111-111111111111"
private let e2eR2 = "22222222-2222-4222-8222-222222222222"
private let e2eR3 = "33333333-3333-4333-8333-333333333333"
private let e2eR4 = "44444444-4444-4444-8444-444444444444"
private let e2eRX = "55555555-5555-4555-8555-555555555555"
private let e2eC1 = "66666666-6666-4666-8666-666666666666"
private let e2eC9 = "99999999-9999-4999-8999-999999999999"
private let e2eRoundtrip = "10101010-1010-4101-8101-101010101010"
private let e2eTamper = "20202020-2020-4202-8202-202020202020"
private let e2eOldBox = "30303030-3030-4303-8303-303030303030"
private let e2eLegacy = "40404040-4040-4404-8404-404040404040"

func makeChildEnv(
    id: String, recipeId: String, at date: Date, device: String,
    deleted: Bool = false, name: String = "Sugar",
    entity: SyncEntityName = .ingredient
) -> SyncEnvelope {
    SyncEnvelope(
        id: id, updatedAt: date, deviceId: device, deleted: deleted,
        entity: entity,
        payload: ["recipeId": .string(recipeId), "name": .string(name)]
    )
}

final class E2EFoldTests: XCTestCase {
    func testFoldRemovesTombstonedChildByAbsence() {
        let parent = makeEnv(id: e2eR1, at: base, device: "seed")
        let live = makeChildEnv(id: e2eC1, recipeId: e2eR1, at: base, device: "seed")
        let tombstone = makeChildEnv(
            id: e2eC1, recipeId: e2eR1,
            at: base.addingTimeInterval(30), device: "device-a", deleted: true
        )
        // First fold embeds c1 live, then the tombstone removes it.
        let withLive = foldEnvelopesForE2E([parent, live])
        XCTAssertEqual(withLive.count, 1)
        XCTAssertEqual(withLive[0].payload["ingredients"]?.arrayValue?.count, 1)
        let folded = foldEnvelopesForE2E(withLive + [tombstone])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].payload["ingredients"]?.arrayValue?.count, 0)
        XCTAssertEqual(folded[0].updatedAt, base.addingTimeInterval(30))
    }

    func testFoldChildLWWNewerWinsStaleLoses() {
        let parent = makeEnv(id: e2eR1, at: base, device: "seed")
        let newer = makeChildEnv(id: e2eC1, recipeId: e2eR1, at: base.addingTimeInterval(20), device: "b", name: "New")
        let folded = foldEnvelopesForE2E([parent, newer])
        XCTAssertEqual(folded[0].payload["ingredients"]?.arrayValue?.first?.objectValue?["name"]?.stringValue, "New")
        // A stale re-push must not clobber the newer embedded child, and the
        // parent timestamp must not move.
        let stale = makeChildEnv(id: e2eC1, recipeId: e2eR1, at: base.addingTimeInterval(5), device: "a", name: "Stale")
        let refolded = foldEnvelopesForE2E(folded + [stale])
        XCTAssertEqual(refolded[0].payload["ingredients"]?.arrayValue?.first?.objectValue?["name"]?.stringValue, "New")
        XCTAssertEqual(refolded[0].updatedAt, base.addingTimeInterval(20))
        // Ties go to incoming (deterministic convergence).
        let tie = makeChildEnv(id: e2eC1, recipeId: e2eR1, at: base.addingTimeInterval(20), device: "c", name: "Tie")
        let retied = foldEnvelopesForE2E(refolded + [tie])
        XCTAssertEqual(retied[0].payload["ingredients"]?.arrayValue?.first?.objectValue?["name"]?.stringValue, "Tie")
    }

    func testStandaloneChildRejectedWithoutParentLink() throws {
        let identity = makeE2EIdentity()
        let orphan = SyncEnvelope(
            id: e2eC9, updatedAt: base, deviceId: "d",
            entity: .ingredient, payload: ["name": .string("NoParent")]
        )
        XCTAssertThrowsError(try e2eEncryptBatch([orphan], identity: identity)) { error in
            guard case E2EError.standaloneChildRejected(let entity, let id) = error else {
                return XCTFail("expected standaloneChildRejected, got \(error)")
            }
            XCTAssertEqual(entity, .ingredient)
            XCTAssertEqual(id, e2eC9)
        }
    }
}

// MARK: - 5. E2E header binding (AES-GCM associated data)

final class E2EHeaderBindingTests: XCTestCase {
    func testRoundTripWithHeaderBinding() throws {
        let identity = makeE2EIdentity()
        let env = makeEnv(id: e2eRoundtrip, at: base, device: "device-a")
        let sealed = try e2eEncrypt(env, identity: identity)
        let opened = try e2eDecrypt(sealed, identity: identity)
        XCTAssertEqual(opened.id, env.id)
        XCTAssertEqual(opened.payload, env.payload)
    }

    func testRoundTripPreservesSubsecondOrdering() throws {
        // Same-second edits must NOT collapse onto one instant: the blind
        // server applies strict LWW (stored wins ties), so flooring to whole
        // seconds would silently discard the loser's outbox entry.
        let identity = makeE2EIdentity()
        let early = makeEnv(id: e2eRoundtrip, at: base.addingTimeInterval(0.2), device: "device-a")
        let late = makeEnv(id: e2eRoundtrip, at: base.addingTimeInterval(0.8), device: "device-b")
        let openedEarly = try e2eDecrypt(try e2eEncrypt(early, identity: identity), identity: identity)
        let openedLate = try e2eDecrypt(try e2eEncrypt(late, identity: identity), identity: identity)
        XCTAssertLessThan(openedEarly.updatedAt, openedLate.updatedAt)
        XCTAssertEqual(
            openedLate.updatedAt.timeIntervalSince1970, 1_790_000_000.8, accuracy: 0.001)
    }

    func testTamperedHeaderFailsOpen() throws {
        let identity = makeE2EIdentity()
        var sealed = try e2eEncrypt(makeEnv(id: e2eTamper, at: base, device: "device-a"), identity: identity)
        sealed.deleted = true // header swap under the same box
        XCTAssertThrowsError(try e2eDecrypt(sealed, identity: identity)) { error in
            guard case E2EError.decryptFailed(let id) = error else {
                return XCTFail("expected decryptFailed, got \(error)")
            }
            XCTAssertEqual(id, e2eTamper)
        }
    }

    func testTamperedSubsecondHeaderFailsOpen() throws {
        // The AD binds whole milliseconds: truncating the timestamp to the
        // second must fail authentication, not decrypt under a forged header.
        let identity = makeE2EIdentity()
        var sealed = try e2eEncrypt(
            makeEnv(id: e2eTamper, at: base.addingTimeInterval(0.5), device: "device-a"),
            identity: identity)
        sealed.updatedAt = base
        XCTAssertThrowsError(try e2eDecrypt(sealed, identity: identity))
    }

    func testPreADBoxIsRejected() throws {
        // Boxes sealed WITHOUT the header binding (pre-AD v2 envelopes) must
        // not open once the binding is required — rejection, no downgrade.
        let identity = makeE2EIdentity()
        let payload: [String: JSONValue] = ["title": "Old"]
        let (nonceB64, ciphertextB64) = try seal(
            JSONEncoder().encode(payload), using: identity.symmetricKey
        )
        let oldBox = EncryptedEnvelope(
            v: 2, alg: "AES-GCM-256",
            kid: identity.kid, householdHash: identity.hash,
            id: e2eOldBox, updatedAt: base, deviceId: "device-a",
            deleted: false, entity: .recipe,
            nonce: nonceB64, ciphertext: ciphertextB64
        )
        XCTAssertThrowsError(try e2eDecrypt(oldBox, identity: identity))
    }

    func testDecryptPrunesLegacyDeletedChildMarkers() throws {
        // Older clients folded tombstones as `deleted: true` markers; those
        // must not restore as live children on apply.
        let identity = makeE2EIdentity()
        let id = e2eLegacy
        let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let payload: [String: JSONValue] = [
            "title": .string("Soup"),
            "ingredients": .array([
                .object(["id": .string("keep"), "name": .string("Salt")]),
                .object(["id": .string("drop"), "name": .string("Pepper"), "deleted": .bool(true)]),
            ]),
        ]
        let ad = e2eHeaderAD(
            v: 2, alg: "AES-GCM-256", kid: identity.kid,
            householdHash: identity.hash, id: id, updatedAt: updatedAt,
            deviceId: "device-a", deleted: false, entity: .recipe
        )
        let (nonceB64, ciphertextB64) = try seal(
            JSONEncoder().encode(payload), using: identity.symmetricKey,
            authenticating: ad
        )
        let legacy = EncryptedEnvelope(
            v: 2, alg: "AES-GCM-256", kid: identity.kid,
            householdHash: identity.hash, id: id, updatedAt: updatedAt,
            deviceId: "device-a", deleted: false, entity: .recipe,
            nonce: nonceB64, ciphertext: ciphertextB64
        )
        let opened = try e2eDecrypt(legacy, identity: identity)
        let ids = opened.payload["ingredients"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        XCTAssertEqual(ids, ["keep"])
    }

    func testPushResponseDecodesStoredShape() throws {
        // Pins the PUT /v2/sync/:hash contract: `{ "stored": [...] }`, not an
        // envelope array.
        let data = Data(#"{"stored":["a","b"]}"#.utf8)
        let decoded = try JSONDecoder().decode(E2EPushResponse.self, from: data)
        XCTAssertEqual(decoded.stored, ["a", "b"])
    }
}

// MARK: - 6. E2E sync (push/pull over the fake /v2 transport)

final class E2ESyncTests: XCTestCase {
    func testTwoEnginesConvergeOverE2E() async throws {
        let server = FakeE2EServer()
        let identity = makeE2EIdentity()
        let engineA = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: FakeServer()))
        let engineB = SyncEngine(deviceId: "device-b", transport: FakeTransport(server: FakeServer()))
        let tA = FakeE2ETransport(server: server, hash: identity.hash)
        let tB = FakeE2ETransport(server: server, hash: identity.hash)

        await engineA.enqueue(makeEnv(id: e2eR1, at: base, device: "device-a"))
        let resA = try await engineA.syncE2E(identity: identity, transport: tA)
        XCTAssertEqual(resA.pushed, 1)
        XCTAssertEqual(resA.conflicts, 0)

        let box = EnvelopeBox()
        let resB = try await engineB.syncE2E(identity: identity, transport: tB, applyRemote: { box.append($0) })
        XCTAssertEqual(resB.pulled, 1)
        XCTAssertEqual(box.all.first?.id, e2eR1)
        let rejectedAfterConverge = await server.rejectedPushes
        XCTAssertEqual(rejectedAfterConverge, [])
    }

    func testPushCountsServerKeptAsConflict() async throws {
        let server = FakeE2EServer()
        let identity = makeE2EIdentity()
        let t = FakeE2ETransport(server: server, hash: identity.hash)
        let engine = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: FakeServer()))

        // Another device's rX@T+300 seeds the pull cursor at T+300.
        let seed = try e2eEncrypt(makeEnv(id: e2eRX, at: base.addingTimeInterval(300), device: "device-b"), identity: identity)
        _ = await server.pushEncrypted(hash: identity.hash, [seed])
        _ = try await engine.syncE2E(identity: identity, transport: t)

        // The server holds r2@T+200 that this client never pulled (below the
        // cursor, so the strict `>` filter will not replay it — e.g. a
        // backdated restore landing after the cursor moved on).
        let serverNewer = try e2eEncrypt(makeEnv(id: e2eR2, at: base.addingTimeInterval(200), device: "device-b"), identity: identity)
        _ = await server.pushEncrypted(hash: identity.hash, [serverNewer])

        // Local r2@T+150 loses the blind push (server keeps T+200): not
        // stored, counted as a conflict, and the SERVER winner is fetched via
        // a full pull and applied before anything is removed — the baseline
        // must land on the winner, never go stale.
        await engine.enqueue(makeEnv(id: e2eR2, at: base.addingTimeInterval(150), device: "device-a"))
        let winBox = EnvelopeBox()
        let pushRes = try await engine.syncE2E(identity: identity, transport: t, applyRemote: { winBox.append($0) })
        XCTAssertEqual(pushRes.pushed, 0)
        XCTAssertEqual(pushRes.conflicts, 1)
        let pendingAfterConflict = await engine.pendingCount
        XCTAssertEqual(pendingAfterConflict, 0)
        XCTAssertEqual(winBox.all.map(\.id), [e2eR2])
        XCTAssertEqual(winBox.all.first?.deviceId, "device-b")
        XCTAssertEqual(winBox.all.first?.updatedAt, base.addingTimeInterval(200))

        // Forward convergence still works: a newer local write stores.
        await engine.enqueue(makeEnv(id: e2eR2, at: base.addingTimeInterval(400), device: "device-a"))
        let res2 = try await engine.syncE2E(identity: identity, transport: t)
        XCTAssertEqual(res2.pushed, 1)
        XCTAssertEqual(res2.conflicts, 0)
    }

    func testPullReplaysEqualTimestamps() async throws {
        let server = FakeE2EServer()
        let identity = makeE2EIdentity()
        let t = FakeE2ETransport(server: server, hash: identity.hash)
        let engine = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: FakeServer()))

        _ = await server.pushEncrypted(
            hash: identity.hash,
            [try e2eEncrypt(makeEnv(id: e2eR3, at: base, device: "seed"), identity: identity)]
        )
        _ = try await engine.syncE2E(identity: identity, transport: t)
        // A same-second write lands AFTER the cursor advanced to `base`.
        _ = await server.pushEncrypted(
            hash: identity.hash,
            [try e2eEncrypt(makeEnv(id: e2eR4, at: base, device: "seed"), identity: identity)]
        )
        let box = EnvelopeBox()
        let res = try await engine.syncE2E(identity: identity, transport: t, applyRemote: { box.append($0) })
        XCTAssertEqual(res.pulled, 1)
        XCTAssertEqual(box.all.first?.id, e2eR4)
        // The second pull rewound one tick so the strict `>` filter replayed
        // the boundary timestamp instead of skipping it.
        let bounds = await server.pullSinceBounds
        XCTAssertEqual(bounds.count, 2)
        XCTAssertEqual(bounds[1], base.addingTimeInterval(-1))
    }

    func testResolveSyncRouteDefaultsToLegacyV1() {
        // No E2E credential in a fresh defaults suite → legacy v1 path.
        let defaults = UserDefaults(suiteName: "smidgen.e2e.route-test")!
        defaults.removePersistentDomain(forName: "smidgen.e2e.route-test")
        defer { defaults.removePersistentDomain(forName: "smidgen.e2e.route-test") }
        guard case .legacyV1 = resolveSyncRoute(defaults: defaults) else {
            return XCTFail("expected legacyV1 without an active credential")
        }
    }

    func testRoutedE2EWithoutTransportFailsClosed() async throws {
        // An E2E route with no E2E transport must throw — never silently fall
        // back to the plaintext v1 sync.
        let engine = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: FakeServer()))
        let identity = makeE2EIdentity()
        do {
            _ = try await engine.syncRouted(route: .e2e(identity))
            XCTFail("expected E2EError.missingTransport")
        } catch let error as E2EError {
            guard case .missingTransport = error else {
                return XCTFail("expected missingTransport, got \(error)")
            }
        }
    }

    func testSameSecondEditsConvergeByMillis() async throws {
        // Two edits inside one wall-clock second: the later-millis write must
        // win the blind push. Whole-second flooring would tie them and the
        // server would keep the first — silently discarding a newer edit.
        let server = FakeE2EServer()
        let identity = makeE2EIdentity()
        let t = FakeE2ETransport(server: server, hash: identity.hash)
        let engineA = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: FakeServer()))
        let engineB = SyncEngine(deviceId: "device-b", transport: FakeTransport(server: FakeServer()))

        await engineA.enqueue(makeEnv(id: e2eR1, at: base.addingTimeInterval(0.2), device: "device-a"))
        let resA = try await engineA.syncE2E(identity: identity, transport: t)
        XCTAssertEqual(resA.pushed, 1)

        await engineB.enqueue(makeEnv(id: e2eR1, at: base.addingTimeInterval(0.8), device: "device-b"))
        let resB = try await engineB.syncE2E(identity: identity, transport: t)
        XCTAssertEqual(resB.pushed, 1)
        XCTAssertEqual(resB.conflicts, 0)

        // A converges onto the millis-newer write.
        let box = EnvelopeBox()
        let resA2 = try await engineA.syncE2E(identity: identity, transport: t, applyRemote: { box.append($0) })
        XCTAssertEqual(resA2.pulled, 1)
        XCTAssertEqual(box.all.first?.deviceId, "device-b")
        let pulledAt = box.all.first?.updatedAt.timeIntervalSince1970 ?? -1
        XCTAssertEqual(
            pulledAt,
            base.addingTimeInterval(0.8).timeIntervalSince1970, accuracy: 0.001)
    }

    func testBucketsAreIsolatedByHash() async throws {
        // Two households, same envelope id: neither bucket may leak into the
        // other, and every returned envelope names its requested bucket.
        let server = FakeE2EServer()
        let identityA = makeE2EIdentity()
        let identityB = E2ESyncIdentity(
            syncCode: "different-code-0987654321", householdId: "hh-test", kid: "testkid0002")
        XCTAssertNotEqual(identityA.hash, identityB.hash)

        let envA = try e2eEncrypt(makeEnv(id: e2eR1, at: base, device: "device-a"), identity: identityA)
        let envB = try e2eEncrypt(makeEnv(id: e2eR1, at: base, device: "device-b"), identity: identityB)
        let storedA = await server.pushEncrypted(hash: identityA.hash, [envA])
        XCTAssertEqual(storedA, [e2eR1])
        let storedB = await server.pushEncrypted(hash: identityB.hash, [envB])
        XCTAssertEqual(storedB, [e2eR1])

        let gotA = await server.pullEncrypted(hash: identityA.hash, since: nil)
        let gotB = await server.pullEncrypted(hash: identityB.hash, since: nil)
        XCTAssertEqual(gotA.count, 1)
        XCTAssertEqual(gotB.count, 1)
        XCTAssertEqual(gotA.first?.householdHash, identityA.hash)
        XCTAssertEqual(gotB.first?.householdHash, identityB.hash)
        XCTAssertEqual(gotA.first?.deviceId, "device-a")
        XCTAssertEqual(gotB.first?.deviceId, "device-b")

        // A cross-bucket push is rejected, never stored.
        let crossStored = await server.pushEncrypted(hash: identityB.hash, [envA])
        XCTAssertEqual(crossStored, [])
        let rejected = await server.rejectedPushes
        XCTAssertEqual(rejected, [e2eR1])
    }
}

// MARK: - 1. Two-device convergence

final class TwoDeviceConvergenceTests: XCTestCase {
    func testTwoDevicesConvergeAfterOfflineEdits() async throws {
        let server = FakeServer()
        let engineA = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: server))
        let engineB = SyncEngine(deviceId: "device-b", transport: FakeTransport(server: server))

        // Both start from the same seed record.
        let seed = makeEnv(id: "r1", at: base, device: "seed")
        _ = await server.push([seed])
        _ = try await engineA.sync()
        _ = try await engineB.sync()

        // Airplane mode: A renames at t+10, B renames at t+20 (B wins).
        await engineA.enqueue(makeEnv(id: "r1", at: base.addingTimeInterval(10), device: "device-a"))
        await engineB.enqueue(makeEnv(id: "r1", at: base.addingTimeInterval(20), device: "device-b"))

        _ = try await engineA.sync() // A pushes t+10
        let resB = try await engineB.sync() // B pulls t+10 (keeps local, newer), pushes t+20
        XCTAssertEqual(resB.pushed, 1)

        // A syncs again and must converge on B's newer write.
        let appliedBox = EnvelopeBox()
        _ = try await engineA.sync(applyRemote: { appliedBox.append($0) })
        XCTAssertEqual(appliedBox.all.count, 1)
        XCTAssertEqual(appliedBox.all.first?.deviceId, "device-b")

        let finalA = await server.store["r1"]
        XCTAssertEqual(finalA?.deviceId, "device-b")
        let pendingA = await engineA.pendingCount
        let pendingB = await engineB.pendingCount
        XCTAssertEqual(pendingA, 0)
        XCTAssertEqual(pendingB, 0)
    }

    func testDeleteTombstoneBeatsOlderLiveRecord() async throws {
        let server = FakeServer()
        let engine = SyncEngine(deviceId: "device-a", transport: FakeTransport(server: server))
        _ = await server.push([makeEnv(id: "r9", at: base, device: "seed")])
        _ = try await engine.sync()
        // Local delete (tombstone) at t+30 must survive push and read back.
        await engine.enqueue(makeEnv(id: "r9", at: base.addingTimeInterval(30),
                                     device: "device-a", deleted: true))
        let res = try await engine.sync()
        XCTAssertEqual(res.pushed, 1)
        let r9deleted = (await server.store["r9"])?.deleted
        XCTAssertEqual(r9deleted, true)
    }
}

// MARK: - 2. Collision matrix (see SYNC_TEST.md for the table)

final class CollisionMatrixTests: XCTestCase {
    func testMatrix() {
        struct Case {
            let name: String
            let local: SyncEnvelope
            let remote: SyncEnvelope
            let expect: MergeOutcome
        }
        let cases: [Case] = [
            Case(name: "remote newer wins",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "b"),
                 expect: .takeRemote),
            Case(name: "local newer wins",
                 local: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "b"),
                 expect: .keepLocal),
            Case(name: "identical no-op",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "a"),
                 expect: .identical),
            Case(name: "tie breaks remote (convergent)",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "b"),
                 expect: .takeRemote),
            Case(name: "newer tombstone deletes",
                 local: makeEnv(id: "x", at: base, device: "a"),
                 remote: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "b", deleted: true),
                 expect: .takeRemote),
            Case(name: "older tombstone loses to live record",
                 local: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "a"),
                 remote: makeEnv(id: "x", at: base, device: "b", deleted: true),
                 expect: .keepLocal),
            Case(name: "resurrect: live write after tombstone wins",
                 local: makeEnv(id: "x", at: base, device: "a", deleted: true),
                 remote: makeEnv(id: "x", at: base.addingTimeInterval(5), device: "b", deleted: false),
                 expect: .takeRemote),
        ]
        for c in cases {
            XCTAssertEqual(mergeOutcome(local: c.local, remote: c.remote), c.expect, c.name)
        }
    }
}

// MARK: - 3. Photo dedup

final class PhotoDedupTests: XCTestCase {
    func testIdenticalBytesShareOneKey() async {
        let engine = SyncEngine(deviceId: "d",
            transport: FakeTransport(server: FakeServer()))
        let bytes = Data("fake-jpeg-bytes".utf8)
        let first = await engine.photoKey(for: bytes)
        let second = await engine.photoKey(for: bytes)
        XCTAssertNotNil(first) // first upload gets a key
        XCTAssertNil(second) // second is a dedup hit
        XCTAssertEqual(first, "photos/" + sha256Hex(of: bytes) + ".jpg")
    }

    func testDifferentBytesGetDifferentKeys() async {
        let engine = SyncEngine(deviceId: "d",
            transport: FakeTransport(server: FakeServer()))
        let k1 = await engine.photoKey(for: Data("photo-one".utf8))
        let k2 = await engine.photoKey(for: Data("photo-two".utf8))
        XCTAssertNotNil(k1)
        XCTAssertNotNil(k2)
        XCTAssertNotEqual(k1, k2)
    }
}
