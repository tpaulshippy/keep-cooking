// Keep Cooking — Lane clients Pass 1: Ed25519 device identity
// apps/ios/Sync/DeviceAuth.swift
//
// Sketch: every install generates an Ed25519 keypair at first launch
// (Keychain, separate from the syncCode/E2EKeyStore entries in
// SyncCrypto.swift), mints a persisted UUIDv4 deviceId bound to that key in
// the Keychain, and enrolls once per API endpoint via
// POST /v2/devices (200/201 mean "enrolled"; 409 means the server holds a
// different key for this id — the client rotates the id and re-enrolls).
//
// Every MUTATING request (POST/PUT/DELETE, incl. /sync/push and the /v2/sync
// PUT) is signed with headers:
//   x-device-id, x-device-ts (unix millis, server Date.now basis),
// where x-device-sig = standard-base64(Ed25519(canonical)) and
//   canonical = METHOD + "\n" + path+query + "\n" + ts + "\n" + hex(SHA256(body))
// (body = raw httpBody, or empty for bodyless requests).
// ts MUST be unix millis: the server verifies against Date.now with a 5min
// skew window, so seconds values always fail verification.
// Reads (GET) carry x-device-id only and keep working without a signature.
//
// Contract notes (match the api lane: MemoryStore.enrollDevice):
//   - publicKey is STANDARD base64 (padded) of exactly 32 bytes.
//   - Re-enroll with the same key is idempotent (200/201); same deviceId +
//     different key is a 409 (server keeps the first key — the client mints
//     a fresh deviceId bound to its key and enrolls that instead).
//
// Non-goals (Pass 1): rotation UI, Keychain sync opt-in, photo routes.
// `userId` ("beta-user") is a display hint only — the device key is the
// identity. identifierForVendor is never sent (it survives reinstalls).
//
// Ordering: direct POST views (clip/caption/share) enroll before sending.
// Sync enrollment is best-effort async (offline safe): a mutating sync
// fired before the first successful enroll goes out signed-but-unknown and
// the server rejects it; enrollment is retried on every app sync / launch,
// so a retry succeeds.

import CryptoKit
import Foundation
import Security
#if os(iOS)
import UIKit
#endif

// MARK: - Canonical string + hashing (pure; unit-testable)

/// Hex SHA-256 of the request body (empty input for bodyless requests).
public func deviceAuthBodyHashHex(_ body: Data?) -> String {
    let data = body ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Path + query as signed, taken from the SERIALIZED request URL
/// (scheme://host stripped). Both platforms sign this exact substring so
/// percent-encoding normalizes identically on iOS and Android (`URL.path`
/// decodes while OkHttp's encodedPath does not — signing either one would
/// diverge on non-ASCII bytes). Empty path becomes "/"; fragments are not
/// signed (never sent on these routes).
public func deviceAuthPathQuery(for url: URL) -> String {
    deviceAuthPathQuery(urlString: url.absoluteString)
}

/// String-level core of `deviceAuthPathQuery(for:)` (unit-testable).
public func deviceAuthPathQuery(urlString: String) -> String {
    var rest = urlString
    if let schemeRange = rest.range(of: "://") {
        rest = String(rest[schemeRange.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return "/" }
        rest = String(rest[slash...])
    }
    if let hash = rest.firstIndex(of: "#") {
        rest = String(rest[..<hash])
    }
    return rest.isEmpty ? "/" : rest
}

/// Canonical bytes: METHOD + "\n" + path+query + "\n" + ts + "\n" + bodyHashHex.
public func deviceAuthCanonical(
    method: String,
    pathQuery: String,
    ts: String,
    bodyHashHex: String
) -> Data {
    Data("\(method.uppercased())\n\(pathQuery)\n\(ts)\n\(bodyHashHex)".utf8)
}

// MARK: - Request signer (Sendable: carries the 32-byte seed, not the key)

/// Value signer for device-authenticated requests. The live
/// `Curve25519.Signing.PrivateKey` is materialized per signing call.
public struct DeviceRequestSigner: Sendable {
    public var deviceId: String
    var seed: Data // 32-byte Ed25519 private seed

    public init(deviceId: String, seed: Data) {
        self.deviceId = deviceId
        self.seed = seed
    }

    /// Signs the canonical string for a request. Returns (ts, sigB64) or nil
    /// when the seed is malformed (caller sends the request unsigned).
    /// ts is unix millis (server Date.now basis — seconds fail verification).
    public func signature(
        method: String,
        pathQuery: String,
        body: Data?,
        ts: String = String(Int(Date().timeIntervalSince1970 * 1000))
    ) -> (ts: String, sigB64: String)? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            return nil
        }
        let canonical = deviceAuthCanonical(
            method: method, pathQuery: pathQuery, ts: ts,
            bodyHashHex: deviceAuthBodyHashHex(body))
        guard let sig = try? key.signature(for: canonical) else { return nil }
        return (ts, Data(sig).base64EncodedString())
    }

    /// Returns a copy of `req` with x-device-id always set, plus x-device-ts
    /// / x-device-sig for mutating methods. Reads (GET/HEAD) stay unsigned.
    /// The httpBody must already be set — the signature binds it.
    public func signedRequest(_ req: URLRequest) -> URLRequest {
        var r = req
        r.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        guard let method = r.httpMethod, method != "GET", method != "HEAD",
              let url = r.url
        else { return r }
        guard let signed = signature(
            method: method,
            pathQuery: deviceAuthPathQuery(for: url),
            body: r.httpBody
        ) else { return r }
        r.setValue(signed.ts, forHTTPHeaderField: "x-device-ts")
        r.setValue(signed.sigB64, forHTTPHeaderField: "x-device-sig")
        return r
    }
}

// MARK: - Device identity (Keychain key + persisted UUID + enroll-once)

public enum DeviceAuth {
    static let service = "smidgen.device"
    static let privateAccount = "smidgen.device.ed25519"
    static let deviceIdKey = "smidgen.device.id"
    static let enrolledFlagPrefix = "smidgen.device.enrolled."

    /// Persisted UUIDv4 device id, BOUND to the Keychain seed. The id and the
    /// seed are kept together in the Keychain: after a device restore the
    /// Keychain seed is gone while UserDefaults survives, so reusing the old
    /// id would skip enrollment with a fresh (server-unknown) key and every
    /// mutating request would fail signature verification. A missing seed
    /// with a surviving id (restore) therefore mints a FRESH id; a missing
    /// seed with no id (fresh install) creates both.
    public static func currentDeviceId(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: deviceIdKey)
        if loadSeed() != nil {
            if let bound = loadKeyedDeviceId(), !bound.isEmpty {
                if bound != stored { defaults.set(bound, forKey: deviceIdKey) }
                return bound
            }
            // Pre-binding seed (written before the id binding existed):
            // bind the surviving id so this install keeps its identity.
            if let s = stored, !s.isEmpty {
                saveKeyedDeviceId(s)
                return s
            }
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: deviceIdKey)
            saveKeyedDeviceId(fresh)
            return fresh
        }
        // No seed: fresh install (no stored id) or restore (stale stored id).
        // Either way the old id must NOT be reused with the new key.
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIdKey)
        if loadOrGenerateSeed() != nil { saveKeyedDeviceId(fresh) }
        return fresh
    }

    /// Mints a fresh deviceId bound to the CURRENT seed (409 recovery: the
    /// server holds a different key for the old id). Updates both the
    /// Keychain binding and UserDefaults so the next signer/enrollment uses
    /// it. Callers must re-read `currentDeviceId()` after enrollment.
    @discardableResult
    public static func rotateDeviceId(defaults: UserDefaults = .standard) -> String {
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIdKey)
        saveKeyedDeviceId(fresh)
        return fresh
    }

    /// Display hint for enrollment (≤64 chars server-side). Not an identity.
    /// Sends nothing identifying (no IDFV — it survives reinstalls and would
    /// undercut the per-install device id): the device model name only.
    public static func displayHint() -> String {
        #if os(iOS)
        let model = UIDevice.current.model // "iPhone"/"iPad" — same for all installs
        return String("iOS \(model)".prefix(64))
        #else
        return "iOS device"
        #endif
    }

    /// Loads the Ed25519 seed from the Keychain, generating + storing on
    /// first launch. Separate entry from the E2E syncCode (SyncCrypto.swift):
    /// rotation of one must never destroy the other.
    public static func loadOrGenerateSeed() -> Data? {
        if let existing = loadSeed() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation
        guard saveSeed(seed) else { return nil }
        return seed
    }

    public static func requestSigner(
        deviceId: String? = nil,
        defaults: UserDefaults = .standard
    ) -> DeviceRequestSigner? {
        let did = deviceId ?? currentDeviceId(defaults: defaults)
        guard let seed = loadOrGenerateSeed() else { return nil }
        return DeviceRequestSigner(deviceId: did, seed: seed)
    }

    public static func publicKeyB64() -> String? {
        guard let seed = loadOrGenerateSeed(),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return nil }
        // Standard base64 (padded) of the 32-byte public key — the api lane
        // rejects base64url / unpadded / wrong-length keys with 400.
        return Data(key.publicKey.rawRepresentation).base64EncodedString()
    }

    /// Enrolled flag for one (deviceId, endpoint) pair. The base URL is part
    /// of the key: switching endpoints must enroll there too instead of
    /// skipping with a key that server has never seen (signed writes would
    /// 401).
    static func enrolledFlag(deviceId: String, baseURL: URL) -> String {
        let flat = baseURL.absoluteString.lowercased().map {
            $0.isLetter || $0.isNumber ? String($0) : "-"
        }.joined()
        return enrolledFlagPrefix + deviceId + "." + flat
    }

    /// POST /v2/devices {deviceId, publicKey, displayName?} — idempotent for
    /// the same key. 200/201 mark this (deviceId, endpoint) enrolled; offline
    /// errors retry on the next launch/sync (reads keep working meanwhile).
    /// 409 means the server holds a DIFFERENT key for this deviceId, so it is
    /// never treated as success: the client mints a fresh deviceId bound to
    /// the current seed and enrolls that instead (one retry). Callers holding
    /// a deviceId must re-read `currentDeviceId()` afterwards.
    public static func enrollIfNeeded(
        baseURL: URL,
        session: URLSession = .shared,
        deviceId: String,
        defaults: UserDefaults = .standard
    ) async {
        var did = deviceId
        for attempt in 0 ..< 2 {
            let flag = enrolledFlag(deviceId: did, baseURL: baseURL)
            if defaults.bool(forKey: flag) { return }
            guard let publicKey = publicKeyB64() else { return }
            let payload: [String: String] = [
                "deviceId": did,
                "publicKey": publicKey,
                "displayName": displayHint(),
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var req = URLRequest(url: baseURL.appendingPathComponent("/v2/devices"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Enrollment is deliberately UNSIGNED: the server does not know this
            // key yet, so there is nothing to verify a signature against.
            // x-device-id rides along for logging correlation only.
            req.setValue(did, forHTTPHeaderField: "x-device-id")
            req.httpBody = body
            do {
                let (_, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if code == 200 || code == 201 {
                    defaults.set(true, forKey: flag)
                    return
                }
                if code == 409, attempt == 0 {
                    // Conflict: server-bound to a different key for this id —
                    // rotate the id and re-enroll, never mark enrolled.
                    did = rotateDeviceId(defaults: defaults)
                    continue
                }
                return
            } catch {
                // Offline — retry next launch/sync.
                return
            }
        }
    }

    // MARK: Keychain (Ed25519 seed + bound device id)

    static let keyedIdAccount = "smidgen.device.keyed-id"

    /// Device id bound to the Keychain seed (kept together: a seed without
    /// its id, or an id without its seed, triggers recovery in
    /// `currentDeviceId()` instead of silent signature failures).
    static func loadKeyedDeviceId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyedIdAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let id = String(data: data, encoding: .utf8),
              !id.isEmpty
        else { return nil }
        return id
    }

    @discardableResult
    static func saveKeyedDeviceId(_ id: String) -> Bool {
        guard let data = id.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyedIdAccount,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func loadSeed() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: privateAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              data.count == 32
        else { return nil }
        return data
    }

    @discardableResult
    static func saveSeed(_ seed: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: privateAccount,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: seed] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = seed
        // Device-only, available after first unlock (background sync safe);
        // Keychain SYNC opt-in is deferred for pass 1.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
