// Keep Cooking — Lane clients Pass 1: Ed25519 device identity
// apps/ios/Sync/DeviceAuth.swift
//
// Sketch: every install generates an Ed25519 keypair at first launch
// (Keychain, separate from the syncCode/E2EKeyStore entries in
// SyncCrypto.swift), mints a persisted UUIDv4 deviceId, and enrolls once via
// POST /v2/devices (idempotent: 200/201/409 all mean "enrolled").
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
//   - Re-enroll with the same key is idempotent; same deviceId + different
//     key is a 409 (server keeps the first key — rotation is a non-goal).
//
// Non-goals (Pass 1): rotation UI, Keychain sync opt-in, photo routes.
// `userId` ("beta-user") and identifierForVendor are display hints only —
// the device key is the identity.
//
// Ordering limitation (Pass 1): enrollment is best-effort async (offline
// safe). A mutating request fired before the first successful enroll goes
// out signed-but-unknown and the server rejects it; enrollment is retried on
// every app sync / launch, so a retry succeeds.

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

    /// Persisted UUIDv4 device id (stable across launches). identifierForVendor
    /// is NOT used here — it is a display hint only (see `displayHint()`).
    public static func currentDeviceId(defaults: UserDefaults = .standard) -> String {
        if let s = defaults.string(forKey: deviceIdKey), !s.isEmpty { return s }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    /// Display hint for enrollment (≤64 chars server-side). Not an identity.
    public static func displayHint() -> String {
        #if os(iOS)
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? "device"
        return String("iOS \(vendor)".prefix(64))
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

    /// POST /v2/devices {deviceId, publicKey, displayName?} — idempotent.
    /// 200/201/409 all mark the device enrolled; offline errors retry on the
    /// next launch/sync (reads keep working meanwhile).
    public static func enrollIfNeeded(
        baseURL: URL,
        session: URLSession = .shared,
        deviceId: String,
        defaults: UserDefaults = .standard
    ) async {
        let flag = enrolledFlagPrefix + deviceId
        if defaults.bool(forKey: flag) { return }
        guard let publicKey = publicKeyB64() else { return }
        let payload: [String: String] = [
            "deviceId": deviceId,
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
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        req.httpBody = body
        do {
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 || code == 201 || code == 409 {
                defaults.set(true, forKey: flag)
            }
        } catch {
            // Offline — retry next launch/sync.
        }
    }

    // MARK: Keychain (Ed25519 seed only)

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
