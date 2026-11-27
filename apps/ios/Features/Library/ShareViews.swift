// Keep Cooking — Lane 5 Organize
// apps/ios/Features/Library/ShareViews.swift
//
// Share UI: household invites + cookbook share links (Lane 1
// POST /share/cookbook, device-signed via DeviceAuth). Lane 5 owns UI +
// signed API call — no sync-engine changes. Every button performs a real action.

import SwiftUI

// MARK: - Household invites

/// Creates invite codes, renders them as shareable links/QR-string, tracks
/// pending invites, and supports revoke. Transport is out-of-band (the
/// ShareLink sheet hands the URL to Messages/Mail); server redemption is a
/// Not-Yet item (see README) with the URL shape already fixed.
public struct HouseholdInvitesView: View {
    @State private var householdId = "hh-demo"
    @State private var invites: [HouseholdInvite] = []
    @State private var error: String?

    public init() {}

    public var body: some View {
        List {
            Section("Household") {
                TextField("Household id", text: $householdId)
                Button("Create invite link") {
                    invites.append(HouseholdInvite.make(householdId: householdId))
                    error = nil
                }
                .disabled(householdId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Pending invites (\(invites.count))") {
                if invites.isEmpty {
                    Text("No invites yet — create one above.").foregroundStyle(.secondary)
                }
                ForEach(invites) { invite in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(invite.code).font(.headline.monospaced())
                        Text("Expires \(invite.expiresAt, style: .date) · \(invite.useCount)/\(invite.maxUses) uses")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let url = invite.inviteURL {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                Button("Copy") {
                                    #if os(iOS)
                                    UIPasteboard.general.string = url.absoluteString
                                    #endif
                                }
                            }
                            Spacer()
                            Button("Revoke") {
                                invites.removeAll { $0.id == invite.id }
                            }
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .opacity(invite.isExpired ? 0.5 : 1)
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Household invites")
    }
}

// MARK: - Cookbook share links

/// Builds a Lane 1 share link for a cookbook. On success shows the URL with
/// ShareLink + Copy; on failure shows the error and keeps the draft (offline
/// retries by tapping again — no silent dead ends).
public struct CookbookShareView: View {
    let cookbook: Cookbook
    @State private var baseURLString: String = CookbookShareView.defaultBaseURL()
    @State private var link: CookbookShareLink?
    @State private var isSharing = false
    @State private var error: String?

    public init(cookbook: Cookbook) { self.cookbook = cookbook }

    public var body: some View {
        Form {
            Section("Endpoint") {
                TextField("API base URL", text: $baseURLString)
            }
            Section("Cookbook") {
                Text("\(cookbook.name) · \(cookbook.recipeIds.count) recipes")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(isSharing ? "Creating…" : "Create share link") {
                    Task { await createShare() }
                }
                .disabled(isSharing || cookbook.recipeIds.isEmpty)
            }
            if let link {
                Section("Share link") {
                    Text(link.url).font(.callout.monospaced()).textSelection(.enabled)
                    Text("Expires \(link.expiresAt)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let url = URL(string: link.url) {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button("Copy") {
                                #if os(iOS)
                                UIPasteboard.general.string = link.url
                                #endif
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Share cookbook")
    }

    private static func defaultBaseURL() -> String {
        if let override = UserDefaults.standard.string(forKey: "smidgen.apiBaseURL"),
           !override.isEmpty {
            return override
        }
        if let s = Bundle.main.object(forInfoDictionaryKey: "SMIDGEN_API_BASE_URL") as? String,
           !s.isEmpty {
            return s
        }
        return SyncConfig.prodBaseURL
    }

    private var currentDeviceId: String {
        // Persisted UUIDv4 (DeviceAuth); identifierForVendor is display-only.
        DeviceAuth.currentDeviceId()
    }

    private func createShare() async {
        guard let base = URL(string: baseURLString) else {
            error = "Invalid base URL."
            return
        }
        UserDefaults.standard.set(baseURLString, forKey: "smidgen.apiBaseURL")
        isSharing = true
        defer { isSharing = false }
        do {
            // Enroll before the first signed POST (fresh installs would get
            // 401 in prod). Re-read the id — 409 recovery rotates it.
            await DeviceAuth.enrollIfNeeded(baseURL: base, deviceId: currentDeviceId)
            let did = currentDeviceId
            let client = ShareAPIClient(baseURL: base,
                betaToken: nil,
                userId: SyncConfig.userId, deviceId: did,
                signer: DeviceAuth.requestSigner(deviceId: did))
            link = try await client.createCookbookShare(
                householdId: cookbook.householdId, recipeIds: cookbook.recipeIds)
            error = nil
        } catch {
            self.error = "Share failed (\(error.localizedDescription)). Check the base URL and retry."
        }
    }
}
