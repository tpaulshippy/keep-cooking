// Keep Cooking — App-scope E2E façade (thin, no crypto here)
// apps/ios/App/BYOE2E.swift
//
// All E2E V1 cryptography lives in apps/ios/Sync (SyncCrypto.swift /
// SyncEngine.swift) against the locked interfaces (see docs/e2e-v1.md):
//   - householdHash = hex SHA-256("smidgen-hh-v1"||syncCode||householdId)
//   - HKDF-SHA256(syncCode, salt "smidgen-sync-v1",
//     info "smidgen-sync-v1/hh:<householdId>/kid:<kid>") -> 32 bytes
//   - AES-GCM-256 envelopes, v:2, on PUT/GET/DELETE /v2/sync/:hash
//   - syncCode lives ONLY in the Keychain
//     (account "smidgen.e2ee.<hashPrefix8>"); UserDefaults holds non-secret
//     metadata only — never the code.
//
// This file only adapts those Sync-layer primitives to Settings UI:
// invite-bundle JSON (out-of-band, QR or manual copy), paste-to-join
// parsing, and first-run identity creation. It holds no secrets and
// performs no crypto.

import Foundation
import Security
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Outcome of a successful paste-to-join (identifiers only, no secrets).
public struct E2EJoinResult: Sendable, Equatable {
    public var householdId: String
    public var kid: String
    public var hashPrefix8: String
    public var endpointHint: String?

    public init(householdId: String, kid: String, hashPrefix8: String, endpointHint: String? = nil) {
        self.householdId = householdId
        self.kid = kid
        self.hashPrefix8 = hashPrefix8
        self.endpointHint = endpointHint
    }
}

public enum E2EJoinError: LocalizedError, Sendable {
    case notInvite
    case hashMismatch
    case kidMismatch
    public var errorDescription: String? {
        switch self {
        case .notInvite: return "That text is not a Keep Cooking invite bundle."
        case .hashMismatch: return "Hash mismatch — code was mistyped or tampered with."
        case .kidMismatch: return "Key ID mismatch — bundle was tampered with or created by an incompatible app."
        }
    }
}

/// Encodes an invite bundle for out-of-band transport (QR / manual copy).
/// Carries householdId, syncCode, kid, hash, endpointHint plus "v":"2".
public func e2eInviteJSONString(_ bundle: SyncInviteBundle) -> String {
    var dict: [String: String] = [
        "v": "2",
        "householdId": bundle.householdId,
        "syncCode": bundle.syncCode,
        "kid": bundle.kid,
        "hash": bundle.hash,
    ]
    if let hint = bundle.endpointHint, !hint.isEmpty {
        dict["endpointHint"] = hint
    }
    let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Parses pasted invite text into a `SyncInviteBundle`, verifying
/// hash == householdHash(syncCode:householdId:) AND kid == kid(syncCode:)
/// before returning. Stores nothing — the caller decides whether to
/// `acceptInvite`.
public func e2eParseInvite(_ pasted: String) throws -> SyncInviteBundle {
    let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = t.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          // Envelope version gate: only v2 bundles are accepted. Check
          // before touching any other field so legacy/forged shapes fail
          // closed here rather than falling through to crypto verification.
          let version = obj["v"], version == "2",
          let householdId = obj["householdId"], !householdId.isEmpty,
          let syncCode = obj["syncCode"], !syncCode.isEmpty,
          let bundleKid = obj["kid"], !bundleKid.isEmpty,
          let hash = obj["hash"], !hash.isEmpty
    else { throw E2EJoinError.notInvite }
    // Recompute the key id from the presented code via the Sync layer hash
    // and reject bundles whose kid does not match — before acceptInvite
    // stores anything. Catches kid-swapping / cross-key paste attacks that
    // hash verification alone would not flag on its own terms.
    guard kid(syncCode: syncCode) == bundleKid else { throw E2EJoinError.kidMismatch }
    let bundle = SyncInviteBundle(
        householdId: householdId,
        syncCode: syncCode,
        kid: bundleKid,
        hash: hash,
        endpointHint: obj["endpointHint"]
    )
    guard bundle.verify() else { throw E2EJoinError.hashMismatch }
    return bundle
}

/// Paste-to-join: parses, verifies (hash == derived), then stores the code
/// in the Keychain + metadata in UserDefaults via `E2EKeyStore`.
/// Returns identifiers only — the code itself never surfaces.
public func e2eJoin(pasted: String) throws -> E2EJoinResult {
    let bundle = try e2eParseInvite(pasted)
    // Defense in depth: re-assert the kid binding immediately before
    // acceptInvite persists anything, even though the parser already checked.
    guard kid(syncCode: bundle.syncCode) == bundle.kid else { throw E2EJoinError.kidMismatch }
    guard E2EKeyStore.acceptInvite(bundle) else { throw E2EJoinError.hashMismatch }
    return E2EJoinResult(
        householdId: bundle.householdId,
        kid: bundle.kid,
        hashPrefix8: String(bundle.hash.prefix(8)),
        endpointHint: bundle.endpointHint
    )
}

/// Creates a fresh household identity (random 32-byte base64 syncCode) and
/// stores it via `E2EKeyStore`. Returns nil only when no identity exists
/// and the code cannot be generated. Existing identities are returned
/// untouched — rotation is a deliberate Settings action, not a side effect.
public func e2eEnsureIdentity(householdId: String) -> E2ECredential? {
    if let active = E2EKeyStore.loadActive() { return active }
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { return nil }
    let syncCode = Data(bytes).base64EncodedString()
    let name = householdId.trimmingCharacters(in: .whitespacesAndNewlines)
    let hh = name.isEmpty ? "hh-demo" : name
    let bundle = SyncInviteBundle.make(
        householdId: hh,
        syncCode: syncCode,
        kid: kid(syncCode: syncCode)
    )
    guard E2EKeyStore.acceptInvite(bundle) else { return nil }
    return E2EKeyStore.loadActive()
}

/// Builds the invite JSON for the active credential (creating a fresh
/// household identity on first run). Nil when the Keychain is unavailable.
public func e2eInviteBundleJSON(householdId: String, endpointHint: String?) -> String? {
    guard let credential = e2eEnsureIdentity(householdId: householdId) else { return nil }
    let bundle = SyncInviteBundle(
        householdId: credential.metadata.householdId,
        syncCode: credential.syncCode,
        kid: credential.metadata.kid,
        hash: credential.metadata.hash,
        endpointHint: endpointHint
    )
    return e2eInviteJSONString(bundle)
}

/// Renders an invite bundle string as a QR code (CoreImage, no deps).
/// Falls back to an empty placeholder when the payload exceeds QR capacity.
struct InviteQRImage: View {
    let payload: String
    var body: some View {
        Group {
            if let img = makeQR(payload) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("Bundle too large for QR",
                    systemImage: "qrcode",
                    description: Text("Use manual copy instead."))
            }
        }
    }

    private func makeQR(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
