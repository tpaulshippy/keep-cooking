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

public protocol SyncTransport: Sendable {
    func pull(since: Date?) async throws -> [SyncEnvelope]
    /// Returns server-won conflict envelopes (empty = all accepted).
    func push(_ envelopes: [SyncEnvelope]) async throws -> [SyncEnvelope]
}

/// URLSession transport against Lane 1 (/sync/pull, /sync/push).
/// Strictly off-main: async/await, JSON with ISO8601 dates.
public struct APISyncTransport: SyncTransport {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
    }

    public func pull(since: Date?) async throws -> [SyncEnvelope] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/sync/pull"), resolvingAgainstBaseURL: false)
        if let since {
            comps?.queryItems = [URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))]
        }
        guard let url = comps?.url else { throw SyncTransportError.badURL }
        let (data, resp) = try await session.data(from: url)
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
        let (data, resp) = try await session.data(for: req)
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

    // MARK: Sync

    /// Pull remote changes, merge LWW, then push the outbox.
    /// `applyRemote` persists a winning remote envelope to SwiftData
    /// (provided by the caller so the engine stays store-agnostic and
    /// testable). Returns counts for UI badges / logging.
    public func sync(applyRemote: (@Sendable (SyncEnvelope) async -> Void)? = nil) async throws -> SyncResult {
        let remote = try await transport.pull(since: lastPulledAt)
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
        // Advance the pull cursor by ENVELOPE time (max updatedAt seen),
        // never wall-clock: backdated restores, clock jumps, or frozen test
        // fixtures would otherwise make pulls silently skip remote writes.
        if let maxRemote = remote.map(\.updatedAt).max() {
            lastPulledAt = max(lastPulledAt ?? .distantPast, maxRemote)
        }

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
