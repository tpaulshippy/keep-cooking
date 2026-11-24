// Smidgen — Lane 2 iOS Foundation
// apps/ios/Sync/SyncEngine.swift
//
// Offline-first sync against Lane 1 contracts:
//   GET /sync/pull?since=ISO8601 -> [SyncEnvelope]
//   POST /sync/push [SyncEnvelope] -> [SyncEnvelope] (server-won conflicts)
//
// Envelope shape (openapi.yaml SyncEnvelope):
//   { id, updatedAt, deviceId, deleted, entity, payload }
//
// Design:
//   - `SyncEnvelope` is a pure Codable Sendable struct (testable, no SwiftData).
//   - `mergeRemote(_:into:)` is a pure LWW function — unit-tested with a
//     2-device convergence scenario + collision matrix (see SyncEngineTests).
//   - `SyncEngine` is an actor: outbox queue, pull/push via async/await,
//     photo SHA-256 dedup before upload. No network on the main thread;
//     views call `await engine.sync()` from .task / refreshable.
//   - `CloudKitMirrorStub` reserves the CloudKit mirror seam (no-op with
//     logging) so a real NSPersistentCloudKitContainer-style mirror can land
//     later without touching call sites.

import Foundation
import CryptoKit

// MARK: - SyncEnvelope (wire shape, 1:1 with openapi.yaml)

public struct SyncEnvelope: Sendable, Codable, Hashable {
    public var id: String
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool
    public var entity: SyncEntityName
    public var payload: [String: JSONValue]

    public init(
        id: String,
        updatedAt: Date,
        deviceId: String,
        deleted: Bool = false,
        entity: SyncEntityName,
        payload: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
        self.entity = entity
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, updatedAt, deviceId, deleted, entity, payload
    }
}

/// JSON scalar tree for envelope payloads — Sendable, Codable and Hashable
/// with no third-party dependency and no type-erased boxes.
public enum JSONValue: Sendable, Codable, Hashable, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Convenience accessors for envelope payload mapping (see SyncCoordinator).
public extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    static func from(_ strings: [String]) -> JSONValue {
        .array(strings.map { .string($0) })
    }
}

// MARK: - Pure merge (LWW + tombstones) — the unit under test

/// Outcome of merging one remote envelope against the local copy.
public enum MergeOutcome: Sendable, Equatable {
    case takeRemote // remote newer (or tie) — apply payload / tombstone
    case keepLocal // local newer — enqueue local for push
    case identical // same updatedAt + same deleted + same device — no-op
}

public func mergeOutcome(local: SyncEnvelope, remote: SyncEnvelope) -> MergeOutcome {
    precondition(local.id == remote.id, "merge requires matching ids")
    if remote.updatedAt > local.updatedAt { return .takeRemote }
    if remote.updatedAt < local.updatedAt { return .keepLocal }
    if remote.deleted == local.deleted, remote.deviceId == local.deviceId { return .identical }
    return .takeRemote // tie-break: remote wins, deterministic convergence
}

// MARK: - Photo SHA-256 dedup

/// Returns the hex SHA-256 of photo bytes. Uploads are skipped when the
/// hash already exists in `knownHashes` (R2 key = photos/<sha256>.jpg).
public func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func photoUploadKeyIfNeeded(bytes: Data, knownHashes: Set<String>) -> String? {
    let hash = sha256Hex(of: bytes)
    if knownHashes.contains(hash) { return nil } // dedup hit — reuse existing key
    return "photos/\(hash).jpg"
}

// MARK: - Transport

public enum SyncTransportError: Error, Sendable {
    case badURL
    case httpStatus(Int)
    case decode(Error)
}

/// Auth headers for the production beta gate + identity.
/// - `betaToken`: `INTERNAL_BETA_TOKEN` (required on prod hosts).
/// - `userId`: shared household identity (beta: "beta-user"; pass 2 = Apple id).
public struct SyncAuth: Sendable {
    public var betaToken: String?
    public var userId: String
    public var deviceId: String
    public init(betaToken: String? = nil, userId: String = "beta-user", deviceId: String) {
        self.betaToken = betaToken; self.userId = userId; self.deviceId = deviceId
    }
}

public protocol SyncTransport: Sendable {
    func pull(since: Date?) async throws -> [SyncEnvelope]
    /// Returns server-won conflict envelopes (empty = all accepted).
    func push(_ envelopes: [SyncEnvelope]) async throws -> [SyncEnvelope]
}

/// URLSession transport against Lane 1 (/sync/pull, /sync/push).
/// Strictly off-main: async/await, JSON with ISO8601 dates.
/// Sends the beta-gate bearer + identity headers when `auth` is set
/// (required on prod `*.workers.dev`; harmless on local dev).
public struct APISyncTransport: SyncTransport {
    private let baseURL: URL
    private let session: URLSession
    private let auth: SyncAuth?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, session: URLSession = .shared, auth: SyncAuth? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.auth = auth
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
    }

    private func authorized(_ req: URLRequest) -> URLRequest {
        var r = req
        guard let auth else { return r }
        if let token = auth.betaToken, !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        r.setValue(auth.userId, forHTTPHeaderField: "x-user-id")
        r.setValue(auth.deviceId, forHTTPHeaderField: "x-device-id")
        return r
    }

    public func pull(since: Date?) async throws -> [SyncEnvelope] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/sync/pull"), resolvingAgainstBaseURL: false)
        if let since {
            comps?.queryItems = [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))]
        }
        guard let url = comps?.url else { throw SyncTransportError.badURL }
        let (data, resp) = try await session.data(for: authorized(URLRequest(url: url)))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SyncTransportError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do { return try decoder.decode([SyncEnvelope].self, from: data) }
        catch { throw SyncTransportError.decode(error) }
    }

    public func push(_ envelopes: [SyncEnvelope]) async throws -> [SyncEnvelope] {
        let url = baseURL.appendingPathComponent("/sync/push")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(envelopes)
        let (data, resp) = try await session.data(for: authorized(req))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SyncTransportError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do { return try decoder.decode([SyncEnvelope].self, from: data) }
        catch { throw SyncTransportError.decode(error) }
    }
}

// MARK: - CloudKit mirror stub

/// Seam for a future CloudKit mirror (NSPersistentCloudKitContainer or
/// explicit CKRecord mapping). Currently a logged no-op so offline-first
/// SwiftData remains the source of truth.
public actor CloudKitMirrorStub {
    public init() {}
    public func mirror(_ envelopes: [SyncEnvelope]) async {
        // Intentional no-op: record count only, no PII in logs.
        _ = envelopes.count
    }
}

// MARK: - E2E V1 encrypted sync (Lane B)

/// Identity for one E2E sync session: bucket hash + key material.
/// The raw 32-byte key is held as `Data` (Sendable-safe); the live
/// `SymmetricKey` is materialized per use via `symmetricKey`.
public struct E2ESyncIdentity: Sendable {
    public var householdId: String
    public var kid: String
    public var hash: String
    public var keyData: Data

    public init(householdId: String, kid: String, hash: String, keyData: Data) {
        self.householdId = householdId
        self.kid = kid
        self.hash = hash
        self.keyData = keyData
    }

    public init(householdId: String, kid: String, hash: String, key: SymmetricKey) {
        self.init(
            householdId: householdId,
            kid: kid,
            hash: hash,
            keyData: key.withUnsafeBytes { Data($0) }
        )
    }

    public init(credential: E2ECredential) {
        self.init(
            householdId: credential.metadata.householdId,
            kid: credential.metadata.kid,
            hash: credential.metadata.hash,
            key: credential.symmetricKey
        )
    }

    /// Derives bucket hash + data key from the invite syncCode (locked
    /// householdHash + HKDF parameters — see SyncCrypto.swift header).
    public init(syncCode: String, householdId: String, kid: String) {
        self.init(
            householdId: householdId,
            kid: kid,
            hash: householdHash(syncCode: syncCode, householdId: householdId),
            key: key(fromCode: syncCode, householdId: householdId, kid: kid)
        )
    }

    public var symmetricKey: SymmetricKey {
        SymmetricKey(data: keyData)
    }
}

public enum E2EError: Error, Sendable {
    /// A standalone ingredient/step envelope reached encryption without a
    /// parent recipe to fold into. The E2E server rejects these (422), so
    /// the client must never emit them.
    case standaloneChildRejected(entity: SyncEntityName, id: String)
    case unsupportedVersion(Int)
    case unsupportedAlg(String)
    case decryptFailed(id: String)
    case payloadDecode(String)
    case payloadEncode(String)
    /// An E2E route was selected but no E2E transport was supplied.
    /// Failing closed: falling back to the plaintext v1 `sync()` here would
    /// silently send household data outside the zero-knowledge channel.
    case missingTransport
}

/// Wire shape for PUT/GET/DELETE /v2/sync/:hash, 1:1 with the server's
/// `encryptedEnvelopeSchema` (api/src/e2e.ts). `v` is always 2 and `alg` is
/// always "AES-GCM-256" (no interop with the v1 plaintext envelope).
/// Every field EXCEPT the sealed payload travels in plaintext so the blind
/// server can LWW-merge on the header; tombstones (`deleted: true`) pass
/// through with an (encrypted) empty/minimal payload.
public struct EncryptedEnvelope: Sendable, Codable, Hashable {
    public var v: Int
    public var alg: String
    public var kid: String
    public var householdHash: String
    public var id: String
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool
    public var entity: SyncEntityName
    public var nonce: String
    public var ciphertext: String

    public init(
        v: Int = 2,
        alg: String = "AES-GCM-256",
        kid: String,
        householdHash: String,
        id: String,
        updatedAt: Date,
        deviceId: String,
        deleted: Bool,
        entity: SyncEntityName,
        nonce: String,
        ciphertext: String
    ) {
        self.v = v
        self.alg = alg
        self.kid = kid
        self.householdHash = householdHash
        self.id = id
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
        self.entity = entity
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

// MARK: Pre-encrypt folding (ingredient/step -> parent recipe)

// Payload keys recognized as the parent link on child envelopes.
private let e2eRecipeIdKeys = ["recipeId", "recipe_id"]

/// Folds ingredient/step envelopes into their parent recipe envelope
/// BEFORE encryption. Children are embedded as entries in the parent's
/// `ingredients` / `steps` payload arrays; the parent's updatedAt bumps only
/// when the fold actually changes content (new entry, winning replacement,
/// or tombstone removal — never on a losing LWW compare).
///
/// Tombstones fold by ABSENCE: a `deleted: true` child REMOVES its entry from
/// the embedded array instead of appending a `deleted: true` marker. The
/// receiver rebuilds children from the embedded set (delete-all + recreate),
/// so a lingering marker would restore the child as live. Absence survives
/// that apply path, and the parent's bumped header LWW decides the winner.
/// (Decrypt additionally prunes any `deleted: true` entries sealed by older
/// clients — see `pruneDeletedFoldedChildren`.)
///
/// Each embedded entry carries the child's own `updatedAt` (epoch millis) +
/// `deviceId` stamps; a re-fold replaces an existing same-id entry only when
/// the incoming child wins that per-child LWW (newer, ties to incoming),
/// so a stale re-push cannot clobber a newer embedded child.
///
/// - Children whose parent recipe envelope is in the same batch merge into it.
/// - Children whose parent is NOT in the batch get a synthesized parent
///   shell (entity `.recipe`, id = recipeId) carrying just the folded
///   children, so no standalone child is ever emitted. A later real recipe
///   envelope for the same id converges via normal header LWW.
/// - Non-child entities (recipe, list, pantryItem, plan, menu) pass through.
/// - A tombstoned recipe passes through untouched (its payload is irrelevant).
public func foldEnvelopesForE2E(_ envelopes: [SyncEnvelope]) -> [SyncEnvelope] {
    var recipes: [String: SyncEnvelope] = [:]
    var recipeOrder: [String] = []
    var passthrough: [SyncEnvelope] = []
    var children: [SyncEnvelope] = []

    for env in envelopes {
        switch env.entity {
        case .recipe:
            if recipes[env.id] == nil { recipeOrder.append(env.id) }
            if let current = recipes[env.id] {
                if env.updatedAt >= current.updatedAt { recipes[env.id] = env }
            } else {
                recipes[env.id] = env
            }
        case .ingredient, .step:
            children.append(env)
        default:
            passthrough.append(env)
        }
    }

    var shellOrder: [String] = []
    var shells: [String: SyncEnvelope] = [:]

    for child in children {
        let parentId = e2eRecipeIdKeys.compactMap { child.payload[$0]?.stringValue }.first
        guard let parentId, !parentId.isEmpty else { continue } // dropped below via encrypt-time guard
        if recipes[parentId] != nil {
            recipes[parentId] = foldChild(child, into: recipes[parentId]!)
        } else if shells[parentId] != nil {
            shells[parentId] = foldChild(child, into: shells[parentId]!)
        } else {
            shellOrder.append(parentId)
            shells[parentId] = foldChild(
                child,
                into: SyncEnvelope(
                    id: parentId,
                    updatedAt: child.updatedAt,
                    deviceId: child.deviceId,
                    entity: .recipe,
                    payload: ["id": .string(parentId), "_foldedShell": .bool(true)]
                )
            )
        }
    }

    // Children with NO recipeId link cannot be folded to a parent; re-emit
    // them unchanged so the encrypt step rejects them loudly (E2EError)
    // instead of silently dropping user data.
    let orphans = children.filter { child in
        e2eRecipeIdKeys.compactMap { child.payload[$0]?.stringValue }.first?.isEmpty ?? true
    }

    return recipeOrder.compactMap { recipes[$0] }
        + shellOrder.compactMap { shells[$0] }
        + passthrough
        + orphans
}

private func foldChild(_ child: SyncEnvelope, into parent: SyncEnvelope) -> SyncEnvelope {
    var parent = parent
    let listKey = child.entity == .ingredient ? "ingredients" : "steps"
    var list = parent.payload[listKey]?.arrayValue ?? []
    let incomingMillis = e2eChildMillis(child.updatedAt)
    if child.deleted {
        // Tombstone-by-absence: drop the embedded entry so the receiver's
        // rebuild restores nothing. No marker is appended (a marker would
        // restore as live on apply).
        let before = list.count
        list.removeAll { $0.objectValue?["id"]?.stringValue == child.id }
        if list.count != before {
            parent.payload[listKey] = .array(list)
            if child.updatedAt > parent.updatedAt {
                parent.updatedAt = child.updatedAt
            }
        }
        return parent
    }
    var entry = child.payload
    entry["id"] = .string(child.id)
    entry["deleted"] = .bool(false)
    entry["updatedAt"] = .int(incomingMillis)
    entry["deviceId"] = .string(child.deviceId)
    var changed = false
    if let index = list.firstIndex(where: { $0.objectValue?["id"]?.stringValue == child.id }) {
        // Per-child LWW: replace only when the incoming child wins.
        // Unstamped (legacy/locally-collected) entries sort as epoch 0, so a
        // real child envelope always wins over them; ties go to incoming,
        // matching the header tie-break (deterministic convergence).
        let existingMillis = list[index].objectValue?["updatedAt"]?.intValue ?? Int.min
        if incomingMillis >= existingMillis {
            list[index] = .object(entry)
            changed = true
        }
    } else {
        list.append(.object(entry))
        changed = true
    }
    if changed {
        parent.payload[listKey] = .array(list)
        if child.updatedAt > parent.updatedAt {
            parent.updatedAt = child.updatedAt
        }
    }
    return parent
}

/// Whole-millisecond instant of a child envelope for embedded LWW stamps.
/// Integer millis are exact through JSON; doubles would risk precision loss.
private func e2eChildMillis(_ date: Date) -> Int {
    Int((date.timeIntervalSince1970 * 1000).rounded())
}

/// The wire id a pending envelope is carried under after folding: standalone
/// children ride inside their parent recipe/shell, everything else under its
/// own id. Used to reconcile the PUT `{stored}` response (which names folded
/// envelope ids) back to pre-fold outbox entries.
private func e2eCarrierId(for envelope: SyncEnvelope) -> String {
    if envelope.entity == .ingredient || envelope.entity == .step {
        if let parentId = e2eRecipeIdKeys.compactMap({ envelope.payload[$0]?.stringValue }).first,
           !parentId.isEmpty
        {
            return parentId
        }
    }
    return envelope.id
}

/// Strips embedded entries still carrying `deleted == true` (sealed by older
/// clients that folded tombstones as markers). New clients fold tombstones by
/// absence and never emit these, but without pruning the receiver's rebuild
/// would restore them as live children. Applied on every decrypt.
private func pruneDeletedFoldedChildren(_ envelope: SyncEnvelope) -> SyncEnvelope {
    var envelope = envelope
    for key in ["ingredients", "steps"] {
        guard let list = envelope.payload[key]?.arrayValue else { continue }
        let live = list.filter { $0.objectValue?["deleted"]?.boolValue != true }
        if live.count != list.count {
            envelope.payload[key] = .array(live)
        }
    }
    return envelope
}

// MARK: Envelope encrypt / decrypt

/// Seals a plaintext envelope's payload; the header stays plaintext but is
/// cryptographically BOUND to the payload via AES-GCM associated data (see
/// `e2eHeaderAD`). `updatedAt` is canonicalized to whole milliseconds first
/// so the seal-time and open-time bindings agree after the JSON round-trip.
/// A header swap in transit fails open (`decryptFailed`).
public func e2eEncrypt(_ envelope: SyncEnvelope, identity: E2ESyncIdentity) throws -> EncryptedEnvelope {
    let sealedAt = canonicalE2ETimestamp(envelope.updatedAt)
    let associatedData = e2eHeaderAD(
        v: 2, alg: "AES-GCM-256",
        kid: identity.kid, householdHash: identity.hash,
        id: envelope.id, updatedAt: sealedAt,
        deviceId: envelope.deviceId, deleted: envelope.deleted,
        entity: envelope.entity
    )
    let payloadData: Data
    do {
        payloadData = try JSONEncoder().encode(envelope.payload)
    } catch {
        throw E2EError.payloadEncode(String(describing: error))
    }
    let (nonceB64, ciphertextB64): (String, String)
    do {
        (nonceB64, ciphertextB64) = try seal(
            payloadData, using: identity.symmetricKey,
            authenticating: associatedData
        )
    } catch {
        throw E2EError.payloadEncode(String(describing: error))
    }
    return EncryptedEnvelope(
        v: 2,
        alg: "AES-GCM-256",
        kid: identity.kid,
        householdHash: identity.hash,
        id: envelope.id,
        updatedAt: sealedAt,
        deviceId: envelope.deviceId,
        deleted: envelope.deleted,
        entity: envelope.entity,
        nonce: nonceB64,
        ciphertext: ciphertextB64
    )
}

/// Opens an encrypted envelope back into a plaintext `SyncEnvelope`.
/// Rejects unknown versions / algorithms BEFORE touching crypto
/// (version-guard), then re-derives the header binding — boxes sealed without
/// it (pre-AD v2 envelopes) or under a tampered header fail authentication
/// and surface as `decryptFailed`. No downgrade path: old boxes are rejected,
/// never silently accepted.
/// LWW merge runs on the resulting header (`updatedAt`); tombstones pass
/// through like any other write. Embedded `deleted: true` child entries from
/// older clients are pruned so they cannot restore as live.
public func e2eDecrypt(_ encrypted: EncryptedEnvelope, identity: E2ESyncIdentity) throws -> SyncEnvelope {
    guard encrypted.v == 2 else {
        throw E2EError.unsupportedVersion(encrypted.v)
    }
    guard encrypted.alg == "AES-GCM-256" else {
        throw E2EError.unsupportedAlg(encrypted.alg)
    }
    let associatedData = e2eHeaderAD(
        v: encrypted.v, alg: encrypted.alg,
        kid: encrypted.kid, householdHash: encrypted.householdHash,
        id: encrypted.id, updatedAt: encrypted.updatedAt,
        deviceId: encrypted.deviceId, deleted: encrypted.deleted,
        entity: encrypted.entity
    )
    let payload: [String: JSONValue]
    do {
        payload = try openJSON(
            nonceB64: encrypted.nonce, ciphertextB64: encrypted.ciphertext,
            using: identity.symmetricKey, authenticating: associatedData
        )
    } catch let error as SyncCryptoError {
        switch error {
        case .payloadDecode(let detail):
            throw E2EError.payloadDecode(detail)
        default:
            throw E2EError.decryptFailed(id: encrypted.id)
        }
    } catch {
        throw E2EError.decryptFailed(id: encrypted.id)
    }
    return pruneDeletedFoldedChildren(SyncEnvelope(
        id: encrypted.id,
        updatedAt: encrypted.updatedAt,
        deviceId: encrypted.deviceId,
        deleted: encrypted.deleted,
        entity: encrypted.entity,
        payload: payload
    ))
}

/// Folds (ingredient/step into parent recipe) then encrypts a batch.
/// Throws `E2EError.standaloneChildRejected` if any ingredient/step has no
/// parent link — the E2E server rejects those with 422, so fail loudly.
public func e2eEncryptBatch(_ envelopes: [SyncEnvelope], identity: E2ESyncIdentity) throws -> [EncryptedEnvelope] {
    let folded = foldEnvelopesForE2E(envelopes)
    for env in folded where env.entity == .ingredient || env.entity == .step {
        throw E2EError.standaloneChildRejected(entity: env.entity, id: env.id)
    }
    return try folded.map { try e2eEncrypt($0, identity: identity) }
}

// MARK: E2E transport (PUT/GET /v2/sync/:hash)

/// Millisecond-precision ISO-8601 for the /v2 wire: always exactly 3
/// fractional digits (`2001-02-03T04:05:06.789Z`). Fixed width keeps LEXICAL
/// string order identical to chronological order, so the server's parsed
/// (`Date.parse`) LWW and its lexical list sort agree on every timestamp this
/// client emits. `JSONEncoder.DateEncodingStrategy.iso8601` drops fractions
/// (second precision), which would collapse same-second edits into ties the
/// blind server resolves against us (`stored` wins ties).
let e2eISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Fallback for DECODING only: accepts older whole-second stamps (server
/// seeds, pre-millis boxes) that carry no fractional part.
private let e2eISO8601FallbackFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.formatOptions = [.withInternetDateTime]
    return f
}()

public protocol E2EEncryptedTransport: Sendable {
    func pullEncrypted(hash: String, since: Date?) async throws -> [EncryptedEnvelope]
    /// Pushes a batch; returns the ids the server newly stored. Ids ABSENT
    /// from the result were NOT overwritten — the server already holds an
    /// equal-or-newer version (stored-wins-ties) and keeps it.
    func pushEncrypted(hash: String, _ envelopes: [EncryptedEnvelope]) async throws -> [String]
}

/// PUT /v2/sync/:hash response body: `{ "stored": [<id>, ...] }` (see
/// api/src/index.ts). This is NOT an envelope array — the blind server never
/// returns conflicting envelopes, only the ids it accepted. Internal (not
/// private) so tests can pin the `{stored}` contract against regressions.
struct E2EPushResponse: Decodable {
    var stored: [String]
}

/// URLSession transport for /v2/sync/:hash, sharing the `baseURL` + auth
/// header convention of `APISyncTransport` (beta bearer + identity headers).
public struct APIE2ETransport: E2EEncryptedTransport {
    private let baseURL: URL
    private let session: URLSession
    private let auth: SyncAuth?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, session: URLSession = .shared, auth: SyncAuth? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.auth = auth
        let d = JSONDecoder()
        // Millis-precision wire (see `e2eISO8601Formatter`); the fallback
        // still opens older whole-second stamps.
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = e2eISO8601Formatter.date(from: s) { return date }
            if let date = e2eISO8601FallbackFormatter.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid E2E date: \(s)")
        }
        self.decoder = d
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            // Canonicalize on the way out too (defense in depth alongside
            // `canonicalE2ETimestamp` in `e2eEncrypt`): the wire never carries
            // more precision than the header AD binds.
            try c.encode(e2eISO8601Formatter.string(from: canonicalE2ETimestamp(date)))
        }
        self.encoder = e
    }

    private func authorized(_ req: URLRequest) -> URLRequest {
        var r = req
        guard let auth else { return r }
        if let token = auth.betaToken, !token.isEmpty {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        r.setValue(auth.userId, forHTTPHeaderField: "x-user-id")
        r.setValue(auth.deviceId, forHTTPHeaderField: "x-device-id")
        return r
    }

    private func bucketURL(hash: String) throws -> URL {
        let comps = URLComponents(
            url: baseURL.appendingPathComponent("/v2/sync/\(hash)"),
            resolvingAgainstBaseURL: false
        )
        guard let url = comps?.url else { throw SyncTransportError.badURL }
        return url
    }

    public func pullEncrypted(hash: String, since: Date?) async throws -> [EncryptedEnvelope] {
        var comps = URLComponents(url: try bucketURL(hash: hash), resolvingAgainstBaseURL: false)
        if let since {
            comps?.queryItems = [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))]
        }
        guard let url = comps?.url else { throw SyncTransportError.badURL }
        let (data, resp) = try await session.data(for: authorized(URLRequest(url: url)))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SyncTransportError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // GET returns a bare array of encrypted envelopes (e2eList) — verify
        // against api/src/index.ts if this decode ever fails.
        do { return try decoder.decode([EncryptedEnvelope].self, from: data) }
        catch { throw SyncTransportError.decode(error) }
    }

    public func pushEncrypted(hash: String, _ envelopes: [EncryptedEnvelope]) async throws -> [String] {
        var req = URLRequest(url: try bucketURL(hash: hash))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(envelopes)
        let (data, resp) = try await session.data(for: authorized(req))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SyncTransportError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // PUT returns `{ "stored": [id] }`, NOT envelopes.
        do { return try decoder.decode(E2EPushResponse.self, from: data).stored }
        catch { throw SyncTransportError.decode(error) }
    }
}

// MARK: - SyncEngine E2E sync

public extension SyncEngine {
    /// E2E sync against /v2/sync/:hash.
    ///
    /// - Outbox envelopes are folded (ingredient/step into parent recipe —
    ///   standalone children are never emitted) and sealed at push time, so
    ///   the outbox stays plaintext and `enqueue(_:)` is unchanged.
    /// - Pull decrypts each envelope, then runs the SAME header-LWW merge
    ///   as v1 (`mergeOutcome` on id/updatedAt/deviceId/deleted).
    /// - Tombstones pass through with their (encrypted) minimal payload.
    /// - Photos stay inline: photo bytes/refs ride inside the sealed payload;
    ///   this path performs no separate upload and ignores `knownPhotoHashes`.
    ///
    /// One engine instance serves ONE mode (v1 or E2E): `outbox`,
    /// `baseline`, and the pull cursor are shared with `sync()`.
    func syncE2E(
        identity: E2ESyncIdentity,
        transport: any E2EEncryptedTransport,
        applyRemote: (@Sendable (SyncEnvelope) async -> Void)? = nil
    ) async throws -> SyncResult {
        // The server compares `updatedAt > since` (strict), so the request
        // rewinds one tick behind the cursor: same-second writes that landed
        // after the cursor advanced would otherwise be skipped forever.
        // Replays are idempotent — `mergeOutcome` dedupes by id (identical =
        // clear outbox, no re-apply, no count).
        let remoteEncrypted = try await transport.pullEncrypted(hash: identity.hash, since: pullSinceDate())
        var remote: [SyncEnvelope] = []
        remote.reserveCapacity(remoteEncrypted.count)
        for enc in remoteEncrypted {
            remote.append(try e2eDecrypt(enc, identity: identity))
        }
        var pulled = await mergePulledRemote(remote, applyRemote: applyRemote)
        advancePullCursor(with: remote)

        let pending = Array(outbox.values)
        var conflicts = 0
        var pushed = 0
        if !pending.isEmpty {
            let encrypted = try e2eEncryptBatch(pending, identity: identity)
            let storedIds = Set(try await transport.pushEncrypted(hash: identity.hash, encrypted))
            // `stored` names folded envelope ids; map pre-fold outbox entries
            // back via their carrier (children ride under the parent id).
            // Stored → accepted (drain + count). Unstored → the server kept an
            // equal-or-newer version (stored-wins-ties) and keeps it. The
            // blind server never returns the winner, so unstored entries stay
            // pending while it is fetched: draining them here would adopt a
            // stale baseline the cursor can never replay (strict `>` filter).
            var unstored: [SyncEnvelope] = []
            for env in pending {
                if storedIds.contains(e2eCarrierId(for: env)) {
                    pushed += 1
                    baseline[env.id] = env
                    outbox.removeValue(forKey: env.id)
                } else {
                    unstored.append(env)
                }
            }
            if !unstored.isEmpty {
                // Force a FULL pull (since: nil): the winner may predate the
                // cursor, so the incremental pull would never replay it.
                // Reconcile through the same header-LWW merge — a newer
                // winner is applied + drained, an identical one just drains —
                // so the baseline always lands on the server version before
                // anything is removed. Entries still pending afterwards lost
                // under a folded parent carrier; they stay queued (never
                // silently dropped) and the conflict is still counted.
                let allEncrypted = try await transport.pullEncrypted(hash: identity.hash, since: nil)
                var winners: [SyncEnvelope] = []
                winners.reserveCapacity(allEncrypted.count)
                for enc in allEncrypted {
                    winners.append(try e2eDecrypt(enc, identity: identity))
                }
                advancePullCursor(with: winners)
                pulled += await mergePulledRemote(winners, applyRemote: applyRemote)
                conflicts += unstored.count
            }
        }
        return SyncResult(pulled: pulled, pushed: pushed, conflicts: conflicts)
    }

    /// Header-LWW merge for pulled E2E envelopes, shared by the incremental
    /// pull and the post-push winner reconcile. Returns the applied count.
    private func mergePulledRemote(
        _ remote: [SyncEnvelope],
        applyRemote: (@Sendable (SyncEnvelope) async -> Void)?
    ) async -> Int {
        var pulled = 0
        for env in remote {
            if let local = outbox[env.id] ?? baseline[env.id] {
                switch mergeOutcome(local: local, remote: env) {
                case .takeRemote:
                    baseline[env.id] = env
                    outbox.removeValue(forKey: env.id)
                    await applyRemote?(env)
                    await mirror.mirror([env])
                    pulled += 1
                case .keepLocal:
                    break
                case .identical:
                    outbox.removeValue(forKey: env.id)
                }
            } else {
                baseline[env.id] = env
                await applyRemote?(env)
                await mirror.mirror([env])
                pulled += 1
            }
        }
        return pulled
    }
}


// MARK: - Sync route (v1 vs E2E credential selection, thin gating)
//
// `resolveSyncRoute()` is the entire credential decision: an active E2E
// credential (`E2EKeyStore.loadActive()`) routes to /v2, otherwise legacy v1.
// `SyncEngine.syncRouted(route:e2eTransport:applyRemote:)` executes it — one
// engine instance serves ONE mode per call, but `outbox`/`baseline`/cursor
// state is shared, so flipping routes never loses pending writes.
//
// Coordinator adoption (apps/ios/App, no UI changes — one call-site swap):
//   let route = resolveSyncRoute()
//   let res = try await engine.syncRouted(
//       route: route,
//       e2eTransport: APIE2ETransport(baseURL: base, auth: auth),
//       applyRemote: { box.append($0) })
/// Which sync backend a sync run should use.
public enum SyncRoute: Sendable {
    case legacyV1
    case e2e(E2ESyncIdentity)
}

/// Credential selection: active E2E credential → /v2, else legacy v1.
public func resolveSyncRoute(defaults: UserDefaults = .standard) -> SyncRoute {
    guard let credential = E2EKeyStore.loadActive(defaults: defaults) else {
        return .legacyV1
    }
    return .e2e(E2ESyncIdentity(credential: credential))
}

public extension SyncEngine {
    /// Runs `syncE2E` when `route` is `.e2e` (and an E2E transport is
    /// supplied), else the legacy v1 `sync()`. A missing E2E transport under
    /// an E2E route throws `E2EError.missingTransport` — failing closed
    /// rather than silently syncing household data over plaintext v1.
    func syncRouted(
        route: SyncRoute,
        e2eTransport: (any E2EEncryptedTransport)? = nil,
        applyRemote: (@Sendable (SyncEnvelope) async -> Void)? = nil
    ) async throws -> SyncResult {
        switch route {
        case .legacyV1:
            return try await sync(applyRemote: applyRemote)
        case .e2e(let identity):
            guard let e2eTransport else {
                throw E2EError.missingTransport
            }
            return try await syncE2E(
                identity: identity, transport: e2eTransport,
                applyRemote: applyRemote
            )
        }
    }
}

// MARK: - SyncEngine (actor: outbox + pull/push orchestration)

public struct SyncResult: Sendable {
    public var pulled: Int
    public var pushed: Int
    public var conflicts: Int
    public init(pulled: Int, pushed: Int, conflicts: Int) {
        self.pulled = pulled
        self.pushed = pushed
        self.conflicts = conflicts
    }
}

public actor SyncEngine {
    public let deviceId: String
    private let transport: any SyncTransport
    private let mirror: CloudKitMirrorStub

    /// Outbox: local envelopes awaiting push, keyed by id (last write wins).
    private var outbox: [String: SyncEnvelope] = [:]
    /// Last-known remote state per id (for merge decisions).
    private var baseline: [String: SyncEnvelope] = [:]
    private var lastPulledAt: Date?
    private var knownPhotoHashes: Set<String> = []

    public init(deviceId: String, transport: any SyncTransport, mirror: CloudKitMirrorStub = CloudKitMirrorStub()) {
        self.deviceId = deviceId
        self.transport = transport
        self.mirror = mirror
    }

    // MARK: Outbox

    public func enqueue(_ envelope: SyncEnvelope) {
        if let existing = outbox[envelope.id] {
            guard envelope.updatedAt >= existing.updatedAt else { return }
        }
        outbox[envelope.id] = envelope
    }

    public var pendingCount: Int { outbox.count }

    // MARK: Photos

    /// Dedup-aware photo key assignment. Returns nil when bytes are already
    /// known (caller reuses the existing R2 key).
    public func photoKey(for bytes: Data) -> String? {
        let key = photoUploadKeyIfNeeded(bytes: bytes, knownHashes: knownPhotoHashes)
        knownPhotoHashes.insert(sha256Hex(of: bytes))
        return key
    }

    public func rememberPhotoHash(_ hex: String) {
        knownPhotoHashes.insert(hex)
    }

    // MARK: Pull cursor ((updatedAt, id) semantics)

    /// The `since` bound for the next pull. Rewinds one tick behind the
    /// cursor because both servers compare strictly (`updatedAt > since`):
    /// without the rewind, same-second writes landing after the cursor
    /// advanced would be skipped on every subsequent pull. Replays are
    /// idempotent (`mergeOutcome` identical → dedupe by id, no re-apply).
    private func pullSinceDate() -> Date? {
        lastPulledAt?.addingTimeInterval(-1)
    }

    /// Advances the cursor by ENVELOPE time (max updatedAt seen), never
    /// wall-clock: backdated restores, clock jumps, or frozen test fixtures
    /// would otherwise make pulls silently skip remote writes. Monotonic —
    /// a pull returning only older replays never moves the cursor back.
    private func advancePullCursor(with remote: [SyncEnvelope]) {
        if let maxRemote = remote.map(\.updatedAt).max() {
            lastPulledAt = max(lastPulledAt ?? .distantPast, maxRemote)
        }
    }

    // MARK: Sync

    /// Pull remote changes, merge LWW, then push the outbox.
    /// `applyRemote` persists a winning remote envelope to SwiftData
    /// (provided by the caller so the engine stays store-agnostic and
    /// testable). Returns counts for UI badges / logging.
    public func sync(applyRemote: (@Sendable (SyncEnvelope) async -> Void)? = nil) async throws -> SyncResult {
        let remote = try await transport.pull(since: pullSinceDate())
        var pulled = 0
        for env in remote {
            // Local truth is the newest local write: a pending outbox entry
            // (unsynced offline edit) shadows the last-synced baseline.
            // Comparing against a stale baseline would silently discard the
            // offline edit the moment any remote version arrives.
            if let local = outbox[env.id] ?? baseline[env.id] {
                switch mergeOutcome(local: local, remote: env) {
                case .takeRemote:
                    baseline[env.id] = env
                    outbox.removeValue(forKey: env.id)
                    await applyRemote?(env)
                    await mirror.mirror([env])
                    pulled += 1
                case .keepLocal:
                    break // stays in outbox for push below
                case .identical:
                    outbox.removeValue(forKey: env.id)
                }
            } else {
                baseline[env.id] = env
                await applyRemote?(env)
                await mirror.mirror([env])
                pulled += 1
            }
        }
        // Advance the pull cursor by ENVELOPE time (see advancePullCursor).
        advancePullCursor(with: remote)

        let pending = Array(outbox.values)
        var conflicts = 0
        var pushed = 0
        if !pending.isEmpty {
            let serverWon = try await transport.push(pending)
            let wonIds = Set(serverWon.map { $0.id })
            conflicts = serverWon.count
            for env in serverWon {
                baseline[env.id] = env
                outbox.removeValue(forKey: env.id)
                await applyRemote?(env)
            }
            for env in pending where !wonIds.contains(env.id) {
                baseline[env.id] = env
                outbox.removeValue(forKey: env.id)
                pushed += 1
            }
        }
        return SyncResult(pulled: pulled, pushed: pushed, conflicts: conflicts)
    }
}
