// Keep Cooking — Lane 5 Organize
// apps/ios/Features/Library/LibraryModels.swift
//
// Lane 5-owned SwiftData models + share DTOs. Core/Models.swift is untouched:
// Recipe/Ingredient/Step conform to the Lane 5 search/dupe protocols here via
// extensions only. New @Model types (Cookbook, SavedSearch) must be registered
// in KeepCookingApp.modelTypes alongside the Lane 2 list.

import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Recipe conformance to Lane 5 protocols

extension Recipe: LibraryRecipe {
    public var recipeId: String { id }
    public var ingredientNames: [String] {
        (ingredients).map { $0.display.isEmpty ? $0.name : $0.display }
    }
    public var stepTexts: [String] { steps.map { $0.text } }
}

extension Recipe: DuplicableRecipe {}

// MARK: - Cookbook (@Model, syncable by id convention)

/// A named collection of recipes. Membership is a JSON id array so Lane 1
/// `POST /share/cookbook { householdId, recipeIds }` can be built directly.
/// Sync: cookbooks ride the recipe envelope family — merges are union-by-id
/// with LWW updatedAt (see CookbookStore).
@Model
public final class Cookbook {
    @Attribute(.unique) public var id: String
    public var householdId: String
    public var name: String
    public var recipeIdsJSON: String // [String] recipe ids
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        name: String,
        recipeIds: [String] = [],
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.recipeIdsJSON = (try? String(data: JSONEncoder().encode(recipeIds), encoding: .utf8)) ?? "[]"
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }

    public var recipeIds: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(recipeIdsJSON.utf8))) ?? [] }
        set { recipeIdsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }
}

// MARK: - SavedSearch (@Model, local-only by design)

/// A named AdvancedFilter. Local-only (never synced): search habits are
/// per-device. `filterData` is JSON-encoded AdvancedFilter.
@Model
public final class SavedSearch {
    @Attribute(.unique) public var id: String
    public var name: String
    public var filterData: Data
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, filter: AdvancedFilter, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.filterData = (try? JSONEncoder().encode(filter)) ?? Data()
        self.createdAt = createdAt
    }

    public var filter: AdvancedFilter? {
        try? JSONDecoder().decode(AdvancedFilter.self, from: filterData)
    }
}

// MARK: - Share DTOs (Codable, transport-agnostic)

/// Household invite: created on-device, sent out-of-band (Messages/Mail via
/// ShareSheet). No server endpoint yet — listed in README "Not Yet"; the code
/// + redemption deep-link shape (`smidgen://invite/<code>`) is already fixed
/// so the server route can land without client changes.
public struct HouseholdInvite: Sendable, Codable, Identifiable {
    public var id: String
    public var householdId: String
    public var code: String
    public var createdAt: Date
    public var expiresAt: Date
    public var maxUses: Int
    public var useCount: Int

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        code: String,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(7 * 86400),
        maxUses: Int = 5,
        useCount: Int = 0
    ) {
        self.id = id
        self.householdId = householdId
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.useCount = useCount
    }

    public var isExpired: Bool { Date() > expiresAt || useCount >= maxUses }
    /// Deep link redeemed by KeepCookingApp.onOpenURL (route stub in README).
    public var inviteURL: URL? { URL(string: "smidgen://invite/\(code)") }

    public static func make(householdId: String) -> HouseholdInvite {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0 ..< 8).map { _ in alphabet.randomElement() ?? "A" })
        return HouseholdInvite(householdId: householdId, code: code)
    }
}

/// Cookbook share link returned by Lane 1 `POST /share/cookbook`.
public struct CookbookShareLink: Sendable, Codable, Identifiable {
    public var id: String
    public var url: String
    public var expiresAt: String
    public init(id: String, url: String, expiresAt: String) {
        self.id = id
        self.url = url
        self.expiresAt = expiresAt
    }
}

// MARK: - Share API client (views call this; no auth/sync changes)

/// Minimal client for Lane 1 share/export routes. Base URL is injected so
/// previews/tests never hit the network. Auth headers intentionally absent:
/// Lane 1 dev store accepts owner role without Better Auth (see api/README);
/// wiring Better Auth tokens is a Not-Yet item, not a silent omission.
public struct ShareAPIClient: Sendable {
    public var baseURL: URL
    public var betaToken: String?
    public var userId: String
    public var deviceId: String
    public init(baseURL: URL, betaToken: String? = nil,
                userId: String = "beta-user", deviceId: String = "app") {
        self.baseURL = baseURL
        self.betaToken = betaToken; self.userId = userId; self.deviceId = deviceId
    }

    public func createCookbookShare(householdId: String, recipeIds: [String], expiresInDays: Int = 30) async throws -> CookbookShareLink {
        var req = URLRequest(url: baseURL.appendingPathComponent("/share/cookbook"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = betaToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(userId, forHTTPHeaderField: "x-user-id")
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        req.httpBody = try JSONEncoder().encode([
            "householdId": AnyCodable(householdId),
            "recipeIds": AnyCodable(recipeIds),
            "expiresInDays": AnyCodable(expiresInDays),
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 201 else {
            throw ShareAPIError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(CookbookShareLink.self, from: data)
    }
}

public enum ShareAPIError: Error, Sendable {
    case httpStatus(Int)
    case decode(Error)
}

/// Type-erased Codable box for the untyped share request dictionary.
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let a = try? c.decode([String].self) { value = a }
        else { value = "" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int: try c.encode(i)
        case let a as [String]: try c.encode(a)
        default: try c.encodeNil()
        }
    }
}
