// Keep Cooking — Lane B ios-crypto-sync (E2E V1)
// apps/ios/Sync/SyncCrypto.swift
//
// Thin E2E V1 client crypto. The server is blind: envelope payloads are
// AES-GCM sealed with a per-household key derived from the user-supplied
// `syncCode`. Only the envelope HEADER (v, id, updatedAt, deviceId,
// deleted, entity, kid — see EncryptedEnvelope in SyncEngine.swift) and
// the household bucket hash travel in plaintext.
//
// Locked interfaces (E2E V1 pass goal):
//   - key(fromCode:householdId:kid:): HKDF<SHA256>(IKM syncCode,
//     salt "smidgen-sync-v1", info "smidgen-sync-v1/hh:<householdId>/kid:<kid>",
//     32 bytes).
//   - seal(payload JSON) -> (nonce b64, ciphertext b64) via AES-GCM;
//     open() is the inverse. `ciphertext` carries ciphertext+tag
//     concatenated (tag = trailing 16 bytes), base-64 encoded.
//   - householdHash(syncCode:householdId:): hex SHA-256 of
//     "smidgen-hh-v1" || syncCode || householdId (UTF-8 concat, matching
//     api/src/e2e.ts). It names the server-side bucket (PUT/GET/DELETE
//     /v2/sync/:hash) without revealing the code.
//   - kid(syncCode:): first 12 chars of base64url(SHA-256(syncCode UTF-8)).
//   - Invite bundle {householdId, syncCode, kid, hash, endpointHint?};
//     the receiver verifies hash == derive before storing anything.
//   - Key storage: the syncCode lives ONLY in the Keychain under account
//     "smidgen.e2ee.<hashPrefix8>" (first 8 hex chars of the household
//     hash). UserDefaults holds ONLY non-secret metadata
//     (kid / household hash / endpoint hint (+ householdId, needed to
//     re-derive the HKDF info string)) — never the code.
//
// No UI here. No photo upload here either: photo bytes/refs stay inline
// inside the encrypted payload (dedicated PUT /v2/photos is deferred).

import CryptoKit
import Foundation
import Security

// MARK: - Key derivation + household hash

/// Derives the 32-byte household data key from the invite syncCode.
///
/// HKDF<SHA256>(IKM: syncCode UTF-8, salt: "smidgen-sync-v1",
/// info: "smidgen-sync-v1/hh:<householdId>/kid:<kid>", L: 32).
public func key(fromCode syncCode: String, householdId: String, kid: String) -> SymmetricKey {
    let ikm = SymmetricKey(data: Data(syncCode.utf8))
    let info = "smidgen-sync-v1/hh:\(householdId)/kid:\(kid)"
    return HKDF<SHA256>.deriveKey(
        inputKeyMaterial: ikm,
        salt: Data("smidgen-sync-v1".utf8),
        info: Data(info.utf8),
        outputByteCount: 32
    )
}

/// Domain separator prefix for household-hash derivation (matches
/// `HOUSEHOLD_HASH_PREFIX` in api/src/e2e.ts).
public let householdHashDomain = "smidgen-hh-v1"

/// Hex SHA-256 of "smidgen-hh-v1" || syncCode || householdId (UTF-8 concat,
/// matching `householdHash()` in api/src/e2e.ts). Names the server bucket
/// (PUT/GET/DELETE /v2/sync/:hash) and the Keychain entry suffix; reveals
/// nothing about the code itself.
public func householdHash(syncCode: String, householdId: String) -> String {
    let input = householdHashDomain + syncCode + householdId
    return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Key id: first 12 chars of base64url(SHA-256(syncCode UTF-8)), no padding.
/// Opaque to the server (header routing only); feeds the HKDF info string.
public func kid(syncCode: String) -> String {
    let digest = SHA256.hash(data: Data(syncCode.utf8))
    let b64 = Data(digest).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return String(b64.prefix(12))
}

/// First 8 hex chars of a household hash — the Keychain account suffix.
public func hashPrefix8(_ hash: String) -> String {
    String(hash.prefix(8))
}

// MARK: - Seal / open (AES-GCM, Data level)

public enum SyncCryptoError: Error, Sendable, Equatable {
    case invalidNonceEncoding
    case invalidCiphertextEncoding
    case malformedNonce
    case malformedCiphertext
    case sealFailed
    case openFailed
    case payloadDecode(String)
}

/// Canonical E2E timestamp: whole milliseconds (floor). The wire encodes
/// `updatedAt` as millisecond-precision ISO-8601 with fixed 3 fractional
/// digits (see `e2eISO8601Formatter` in SyncEngine.swift), so both seal and
/// open bind the same instant after the JSON round-trip. Flooring to whole
/// *seconds* would collapse same-second edits onto one instant; the blind
/// server applies strict parsed LWW (`stored` wins ties) and would silently
/// drop the loser, so subsecond ordering is preserved end to end.
public func canonicalE2ETimestamp(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1000) / 1000)
}

/// Domain separator for the E2E header associated-data binding.
public let e2eADContext = "smidgen-e2e-ad-v1"

/// Canonical associated data binding the sealed payload to its plaintext
/// routing header. AES-GCM authenticates (but does not encrypt) these bytes,
/// so a blind-server header swap (id/entity/updatedAt/tombstone/kid/bucket)
/// fails open instead of decrypting under a forged header. Encoded as a JSON
/// string array — deterministic and unambiguous without locale pitfalls.
/// `updatedAt` binds whole MILLISECONDS (see `canonicalE2ETimestamp`) so
/// seal-time and open-time agree, including the subsecond part: binding only
/// whole seconds would let a same-second timestamp swap pass authentication.
/// The wire always carries fixed 3-digit fractional seconds (see
/// `e2eISO8601Formatter`), so the server's parsed (`Date.parse`) and lexical
/// orderings agree on every timestamp this client emits.
/// NOTE: boxes sealed under the old whole-second binding are rejected as
/// `decryptFailed` (fail closed, like pre-AD boxes) — no downgrade path.
public func e2eHeaderAD(
    v: Int,
    alg: String,
    kid: String,
    householdHash: String,
    id: String,
    updatedAt: Date,
    deviceId: String,
    deleted: Bool,
    entity: SyncEntityName
) -> Data {
    let millis = Int64(floor(updatedAt.timeIntervalSince1970 * 1000))
    let parts = [
        e2eADContext, String(v), alg, kid, householdHash, id,
        String(millis), deviceId, deleted ? "1" : "0", entity.rawValue,
    ]
    // JSON string-array encoding cannot realistically fail; the unit
    // separator fallback preserves determinism if it ever does.
    return (try? JSONEncoder().encode(parts))
        ?? Data(parts.joined(separator: "\u{1F}").utf8)
}

/// AES-GCM seals `payload`. Returns base-64 `(nonce, ciphertext)` where
/// `ciphertext` is raw-ciphertext ‖ 16-byte tag, base-64 encoded.
/// `authenticating`, when non-empty, is bound as associated data: open must
/// present the identical bytes or authentication fails. Boxes sealed WITHOUT
/// associated data (pre-AD v2 envelopes) do NOT open when AD is required —
/// that rejection is intentional (no downgrade path).
public func seal(
    _ payload: Data,
    using symmetricKey: SymmetricKey,
    authenticating associatedData: Data? = nil
) throws -> (nonceB64: String, ciphertextB64: String) {
    let sealedBox: AES.GCM.SealedBox
    do {
        sealedBox = try AES.GCM.seal(
            payload, using: symmetricKey,
            authenticating: associatedData ?? Data()
        )
    } catch {
        throw SyncCryptoError.sealFailed
    }
    let nonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }
    var combined = sealedBox.ciphertext
    combined.append(contentsOf: sealedBox.tag)
    return (nonceB64: nonceData.base64EncodedString(), ciphertextB64: combined.base64EncodedString())
}

/// Inverse of `seal(_:using:authenticating:)`. Throws `SyncCryptoError` (never the
/// underlying CryptoKit error, which can carry key-material-adjacent detail).
/// A wrong `authenticating` value (e.g. a tampered header, or an old box
/// opened under the new AD binding) surfaces as `openFailed`.
public func open(
    nonceB64: String,
    ciphertextB64: String,
    using symmetricKey: SymmetricKey,
    authenticating associatedData: Data? = nil
) throws -> Data {
    guard let nonceData = Data(base64Encoded: nonceB64) else {
        throw SyncCryptoError.invalidNonceEncoding
    }
    guard let combined = Data(base64Encoded: ciphertextB64) else {
        throw SyncCryptoError.invalidCiphertextEncoding
    }
    guard nonceData.count == 12, let nonce = try? AES.GCM.Nonce(data: nonceData) else {
        throw SyncCryptoError.malformedNonce
    }
    guard combined.count >= 16 else {
        throw SyncCryptoError.malformedCiphertext
    }
    let ciphertext = combined.prefix(combined.count - 16)
    let tag = combined.suffix(16)
    guard let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else {
        throw SyncCryptoError.malformedCiphertext
    }
    do {
        return try AES.GCM.open(
            sealedBox, using: symmetricKey,
            authenticating: associatedData ?? Data()
        )
    } catch {
        throw SyncCryptoError.openFailed
    }
}

// MARK: - Seal / open (envelope-payload JSON level)

/// Seals a `[String: JSONValue]` envelope payload (canonical JSON encoding).
/// Pass the envelope's `e2eHeaderAD(...)` as `authenticating` so the payload
/// is bound to its plaintext header (E2E path always does).
public func sealJSON(
    _ payload: [String: JSONValue],
    using symmetricKey: SymmetricKey,
    authenticating associatedData: Data? = nil
) throws -> (nonceB64: String, ciphertextB64: String) {
    let data = try JSONEncoder().encode(payload)
    return try seal(data, using: symmetricKey, authenticating: associatedData)
}

/// Inverse of `sealJSON(_:using:authenticating:)`.
public func openJSON(
    nonceB64: String,
    ciphertextB64: String,
    using symmetricKey: SymmetricKey,
    authenticating associatedData: Data? = nil
) throws -> [String: JSONValue] {
    let data = try open(
        nonceB64: nonceB64, ciphertextB64: ciphertextB64,
        using: symmetricKey, authenticating: associatedData
    )
    do {
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    } catch {
        throw SyncCryptoError.payloadDecode(String(describing: error))
    }
}

// MARK: - Invite bundle

/// Share payload for adding a device to a household. Transported out of
/// band (QR / message); the receiver MUST call `verify()` (hash ==
/// derived household hash) before persisting anything.
public struct SyncInviteBundle: Sendable, Codable, Hashable {
    public var householdId: String
    public var syncCode: String
    public var kid: String
    public var hash: String
    public var endpointHint: String?

    public init(householdId: String, syncCode: String, kid: String, hash: String, endpointHint: String? = nil) {
        self.householdId = householdId
        self.syncCode = syncCode
        self.kid = kid
        self.hash = hash
        self.endpointHint = endpointHint
    }

    /// True when `hash` equals the hash derived from `syncCode`+`householdId`.
    public func verify() -> Bool {
        hash == householdHash(syncCode: syncCode, householdId: householdId)
    }

    /// Builds a self-consistent bundle (hash derived, not caller-supplied).
    public static func make(householdId: String, syncCode: String, kid: String, endpointHint: String? = nil) -> SyncInviteBundle {
        SyncInviteBundle(
            householdId: householdId,
            syncCode: syncCode,
            kid: kid,
            hash: householdHash(syncCode: syncCode, householdId: householdId),
            endpointHint: endpointHint
        )
    }
}

// MARK: - Key storage (Keychain for the code, UserDefaults for metadata)

/// Non-secret E2E metadata persisted in UserDefaults. The syncCode itself
/// NEVER touches UserDefaults — it lives only in the Keychain.
public struct E2EMetadata: Sendable, Equatable {
    public var householdId: String
    public var kid: String
    public var hash: String
    public var endpointHint: String?

    public init(householdId: String, kid: String, hash: String, endpointHint: String? = nil) {
        self.householdId = householdId
        self.kid = kid
        self.hash = hash
        self.endpointHint = endpointHint
    }
}

/// Active credential: metadata + the Keychain-held code + derived key.
public struct E2ECredential: Sendable {
    public var metadata: E2EMetadata
    public var syncCode: String

    public init(metadata: E2EMetadata, syncCode: String) {
        self.metadata = metadata
        self.syncCode = syncCode
    }

    /// Derives the household data key for this credential.
    public var symmetricKey: SymmetricKey {
        key(fromCode: syncCode, householdId: metadata.householdId, kid: metadata.kid)
    }
}

public enum E2EKeyStore {
    private static let service = "smidgen.e2ee"
    private static let kidKey = "smidgen.e2ee.kid"
    private static let hashKey = "smidgen.e2ee.householdHash"
    private static let endpointHintKey = "smidgen.e2ee.endpointHint"
    private static let householdIdKey = "smidgen.e2ee.householdId"

    /// Keychain account for a household bucket: "smidgen.e2ee.<hashPrefix8>".
    public static func keychainAccount(hash: String) -> String {
        "smidgen.e2ee.\(hashPrefix8(hash))"
    }

    // MARK: Keychain (secret: syncCode only)

    @discardableResult
    public static func saveSyncCode(_ syncCode: String, hash: String) -> Bool {
        let account = keychainAccount(hash: hash)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place when the item already exists: the old secret stays
        // readable until the new bytes commit, and a failure (e.g. device
        // lock) never destroys the working credential. Add only when missing.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: Data(syncCode.utf8)] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = Data(syncCode.utf8)
        // Device-only, available after first unlock (background sync safe);
        // Keychain SYNC opt-in is deferred for pass 1.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func loadSyncCode(hash: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(hash: hash),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let code = String(data: data, encoding: .utf8),
              !code.isEmpty
        else { return nil }
        return code
    }

    @discardableResult
    public static func deleteSyncCode(hash: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(hash: hash),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: UserDefaults (non-secret metadata only)

    public static func saveMetadata(_ metadata: E2EMetadata, defaults: UserDefaults = .standard) {
        defaults.set(metadata.kid, forKey: kidKey)
        defaults.set(metadata.hash, forKey: hashKey)
        defaults.set(metadata.householdId, forKey: householdIdKey)
        if let hint = metadata.endpointHint {
            defaults.set(hint, forKey: endpointHintKey)
        } else {
            defaults.removeObject(forKey: endpointHintKey)
        }
    }

    public static func loadMetadata(defaults: UserDefaults = .standard) -> E2EMetadata? {
        guard let kid = defaults.string(forKey: kidKey),
              let hash = defaults.string(forKey: hashKey),
              let householdId = defaults.string(forKey: householdIdKey),
              !kid.isEmpty, !hash.isEmpty, !householdId.isEmpty
        else { return nil }
        return E2EMetadata(
            householdId: householdId,
            kid: kid,
            hash: hash,
            endpointHint: defaults.string(forKey: endpointHintKey)
        )
    }

    public static func clearMetadata(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: kidKey)
        defaults.removeObject(forKey: hashKey)
        defaults.removeObject(forKey: householdIdKey)
        defaults.removeObject(forKey: endpointHintKey)
    }

    // MARK: High-level invite flows

    /// Verifies the bundle (hash == derive), then stores the code in the
    /// Keychain and the metadata in UserDefaults. Returns false when the
    /// bundle fails verification (nothing is stored). The Keychain write
    /// commits FIRST: metadata is persisted only after the secret is safe,
    /// so a Keychain failure leaves the prior credential fully intact
    /// (metadata still points at the old, still-present code).
    @discardableResult
    public static func acceptInvite(_ bundle: SyncInviteBundle, defaults: UserDefaults = .standard) -> Bool {
        guard bundle.verify() else { return false }
        guard saveSyncCode(bundle.syncCode, hash: bundle.hash) else { return false }
        let metadata = E2EMetadata(
            householdId: bundle.householdId,
            kid: bundle.kid,
            hash: bundle.hash,
            endpointHint: bundle.endpointHint
        )
        saveMetadata(metadata, defaults: defaults)
        return true
    }

    /// Loads the active credential: metadata from UserDefaults + code from
    /// the Keychain, re-verifying hash == derive before returning.
    public static func loadActive(defaults: UserDefaults = .standard) -> E2ECredential? {
        guard let metadata = loadMetadata(defaults: defaults) else { return nil }
        guard let code = loadSyncCode(hash: metadata.hash) else { return nil }
        guard householdHash(syncCode: code, householdId: metadata.householdId) == metadata.hash else { return nil }
        return E2ECredential(metadata: metadata, syncCode: code)
    }

    /// Removes both the Keychain code and the UserDefaults metadata.
    public static func reset(defaults: UserDefaults = .standard, hash: String? = nil) {
        let targetHash = hash ?? defaults.string(forKey: hashKey)
        if let targetHash, !targetHash.isEmpty {
            deleteSyncCode(hash: targetHash)
        }
        clearMetadata(defaults: defaults)
    }
}
