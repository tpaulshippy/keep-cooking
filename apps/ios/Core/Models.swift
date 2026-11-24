// Keep Cooking — Lane 2 iOS Foundation
// apps/ios/Core/Models.swift
//
// SwiftData models 1:1 with packages/contracts/schema.sql (v0.1.0)
// + packages/contracts/openapi.yaml component schemas.
//
// Sync contract (all top-level entities):
//   id TEXT PK (uuid) · updatedAt ISO8601 · deviceId TEXT · deleted 0/1 tombstone
//   Last-write-wins on updatedAt. Deleted tombstones win like any other write.
//   Child rows (Ingredient / Step / ListItem) version through their parent
//   envelope but also carry sync fields so they can merge standalone.
//
// Rules: SwiftUI + SwiftData only. Strict concurrency (Sendable where
// possible, @MainActor for model mutation). No force-unwrap in prod paths.
// No network here — all transport lives in SyncEngine.

import Foundation
import SwiftData

// MARK: - Shared sync primitives

/// Sync entity names — must match openapi.yaml SyncEnvelope.entity enum:
/// recipe | ingredient | step | list | pantryItem | plan | menu
public enum SyncEntityName: String, Sendable, Codable, CaseIterable {
    case recipe
    case ingredient
    case step
    case list
    case pantryItem
    case plan
    case menu
}

/// Plan meal slot — matches schema.sql CHECK + openapi Plan.meal enum.
public enum MealSlot: String, Sendable, Codable, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case snack
}

/// Anything that can ride a SyncEnvelope.
/// NOTE: @Model classes are main-actor confined and explicitly non-Sendable
/// (SwiftData marks Sendable unavailable). Only the Codable SyncEnvelope
/// snapshot crosses actor boundaries — never the model itself.
public protocol Syncable: AnyObject {
    var syncId: String { get }
    var syncUpdatedAt: Date { get set }
    var syncDeviceId: String { get set }
    var syncDeleted: Bool { get set }
    var syncEntity: SyncEntityName { get }
}

public enum SyncMergeDecision: Sendable {
    case keepLocal
    case takeRemote
}

/// Pure last-write-wins: later updatedAt wins; ties break toward remote
/// (deterministic so two devices converge). Tombstones are just writes —
/// a newer `deleted=true` beats an older live record and vice versa.
public func resolveSyncWinner(localUpdatedAt: Date, remoteUpdatedAt: Date) -> SyncMergeDecision {
    if remoteUpdatedAt >= localUpdatedAt { return .takeRemote }
    return .keepLocal
}

// MARK: - JSON helpers (TEXT columns holding '[]' JSON per schema.sql)

/// Encode `value` to a JSON string, falling back to `"[]"` — never throws,
/// never force-unwraps.
 fileprivate func encodeJSONArray<T: Encodable>(_ value: T) -> String {
    if let data = try? JSONEncoder().encode(value),
       let json = String(data: data, encoding: .utf8)
    {
        return json
    }
    return "[]"
}

 fileprivate func decodeJSONArray<T: Decodable>(_ type: T.Type, from json: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(json.utf8))
}

// MARK: - Recipe (recipes table)

@Model
public final class Recipe {
    @Attribute(.unique) public var id: String
    public var householdId: String
    public var title: String
    public var recipeDescription: String
    public var servings: Double
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var rating: Double?
    public var source: String
    public var sourceUrl: String
    public var categoriesJSON: String // [String] encoded — schema.sql categories TEXT DEFAULT '[]'
    public var photoOriginal: String?
    public var photoLarge1024: String?
    public var photoThumb: String?
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe)
    public var ingredients: [Ingredient] = []
    @Relationship(deleteRule: .cascade, inverse: \Step.recipe)
    public var steps: [Step] = []

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        title: String,
        recipeDescription: String = "",
        servings: Double = 4,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        rating: Double? = nil,
        source: String = "",
        sourceUrl: String = "",
        categories: [String] = [],
        photoOriginal: String? = nil,
        photoLarge1024: String? = nil,
        photoThumb: String? = nil,
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.householdId = householdId
        self.title = title
        self.recipeDescription = recipeDescription
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.rating = rating
        self.source = source
        self.sourceUrl = sourceUrl
        self.categoriesJSON = encodeJSONArray(categories)
        self.photoOriginal = photoOriginal
        self.photoLarge1024 = photoLarge1024
        self.photoThumb = photoThumb
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }

    public var categories: [String] {
        get { decodeJSONArray([String].self, from: categoriesJSON) ?? [] }
        set { categoriesJSON = encodeJSONArray(newValue) }
    }
}

extension Recipe: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .recipe }
}

// MARK: - Ingredient (ingredients table)

@Model
public final class Ingredient {
    @Attribute(.unique) public var id: String
    public var recipeId: String
    public var name: String
    public var quantity: Double?
    public var unit: String
    public var display: String
    public var position: Int
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public var recipe: Recipe?

    public init(
        id: String = UUID().uuidString,
        recipeId: String,
        name: String,
        quantity: Double? = nil,
        unit: String = "",
        display: String = "",
        position: Int = 0,
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.recipeId = recipeId
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.display = display
        self.position = position
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }
}

extension Ingredient: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .ingredient }
}

// MARK: - Step (steps table)

/// Named `Step` per the contract entity enum (`entity: "step"`).
@Model
public final class Step {
    @Attribute(.unique) public var id: String
    public var recipeId: String
    public var position: Int
    public var text: String
    public var timersJSON: String // [StepTimer] encoded — schema.sql timers TEXT DEFAULT '[]'
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public var recipe: Recipe?

    public init(
        id: String = UUID().uuidString,
        recipeId: String,
        position: Int,
        text: String,
        timers: [StepTimer] = [],
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.recipeId = recipeId
        self.position = position
        self.text = text
        self.timersJSON = encodeJSONArray(timers)
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }

    public var timers: [StepTimer] {
        get { decodeJSONArray([StepTimer].self, from: timersJSON) ?? [] }
        set { timersJSON = encodeJSONArray(newValue) }
    }
}

extension Step: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .step }
}

/// Codable timer embedded in Step.timersJSON. Matches openapi StepTimer.
public struct StepTimer: Sendable, Codable, Hashable {
    public var seconds: Int
    public var label: String
    public init(seconds: Int, label: String) {
        self.seconds = seconds
        self.label = label
    }
}

// MARK: - ShoppingList (shopping_lists table)

@Model
public final class ShoppingList {
    @Attribute(.unique) public var id: String
    public var householdId: String
    public var name: String
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    @Relationship(deleteRule: .cascade, inverse: \ListItem.shoppingList)
    public var items: [ListItem] = []

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        name: String,
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }
}

extension ShoppingList: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .list }
}

// MARK: - ListItem (list_items table)

@Model
public final class ListItem {
    @Attribute(.unique) public var id: String
    public var listId: String
    public var name: String
    public var quantity: String
    public var aisle: String
    public var checked: Bool
    public var recipeId: String?
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public var shoppingList: ShoppingList?

    public init(
        id: String = UUID().uuidString,
        listId: String,
        name: String,
        quantity: String = "",
        aisle: String = "",
        checked: Bool = false,
        recipeId: String? = nil,
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.listId = listId
        self.name = name
        self.quantity = quantity
        self.aisle = aisle
        self.checked = checked
        self.recipeId = recipeId
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }
}

extension ListItem: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .list }
}

// MARK: - PantryItem (pantry_items table)

@Model
public final class PantryItem {
    @Attribute(.unique) public var id: String
    public var householdId: String
    public var name: String
    public var quantity: String
    public var location: String
    public var expiresAt: Date?
    public var lowThreshold: String
    public var barcode: String
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        name: String,
        quantity: String = "",
        location: String = "",
        expiresAt: Date? = nil,
        lowThreshold: String = "",
        barcode: String = "",
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.quantity = quantity
        self.location = location
        self.expiresAt = expiresAt
        self.lowThreshold = lowThreshold
        self.barcode = barcode
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }
}

extension PantryItem: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .pantryItem }
}

// MARK: - Plan (plans table)

@Model
public final class Plan {
    @Attribute(.unique) public var id: String
    public var householdId: String
    public var date: Date // day precision; schema.sql date TEXT (YYYY-MM-DD)
    public var mealRaw: String // MealSlot rawValue — CHECK(meal IN (...)) in SQL
    public var recipeId: String?
    public var note: String
    public var servings: Double?
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        date: Date,
        meal: MealSlot,
        recipeId: String? = nil,
        note: String = "",
        servings: Double? = nil,
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.householdId = householdId
        self.date = date
        self.mealRaw = meal.rawValue
        self.recipeId = recipeId
        self.note = note
        self.servings = servings
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }

    public var meal: MealSlot {
        get { MealSlot(rawValue: mealRaw) ?? .dinner }
        set { mealRaw = newValue.rawValue }
    }
}

extension Plan: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .plan }
}

// MARK: - Menu (menus table)

@Model
public final class Menu {
    @Attribute(.unique) public var id: String
    public var householdId: String
    public var name: String
    public var entriesJSON: String // [MenuEntry] encoded — schema.sql entries TEXT DEFAULT '[]'
    public var updatedAt: Date
    public var deviceId: String
    public var deleted: Bool

    public init(
        id: String = UUID().uuidString,
        householdId: String,
        name: String,
        entries: [MenuEntry] = [],
        updatedAt: Date = Date(),
        deviceId: String,
        deleted: Bool = false
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.entriesJSON = encodeJSONArray(entries)
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deleted = deleted
    }

    public var entries: [MenuEntry] {
        get { decodeJSONArray([MenuEntry].self, from: entriesJSON) ?? [] }
        set { entriesJSON = encodeJSONArray(newValue) }
    }
}

extension Menu: Syncable {
    public var syncId: String { id }
    public var syncUpdatedAt: Date { get { updatedAt } set { updatedAt = newValue } }
    public var syncDeviceId: String { get { deviceId } set { deviceId = newValue } }
    public var syncDeleted: Bool { get { deleted } set { deleted = newValue } }
    public var syncEntity: SyncEntityName { .menu }
}

/// Codable menu entry embedded in Menu.entriesJSON. Matches openapi Menu entries.
public struct MenuEntry: Sendable, Codable, Hashable {
    public var dayOffset: Int
    public var meal: String
    public var recipeId: String
    public var servings: Double
    public init(dayOffset: Int, meal: String, recipeId: String, servings: Double) {
        self.dayOffset = dayOffset
        self.meal = meal
        self.recipeId = recipeId
        self.servings = servings
    }
}
