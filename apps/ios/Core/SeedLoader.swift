// Keep Cooking — Lane 2 iOS Foundation
// apps/ios/Core/SeedLoader.swift
//
// Loads frozen contract seeds (packages/contracts/seed/*.json, 15 recipes)
// into SwiftData so the app demos in airplane mode with zero network.
// All file I/O + decode runs off the main thread; inserts happen on @MainActor.
//
// Seed JSON shape: SyncEnvelope-flavoured Recipe objects (id, updatedAt,
// deviceId, deleted, entity + recipe fields + ingredients[] + steps[]).

import Foundation
import SwiftData

// MARK: - Decodable seed DTOs (mirror contracts/seed/*.json, NOT the @Models)

public struct SeedIngredientDTO: Sendable, Codable {
    public var id: String
    public var name: String
    public var quantity: Double?
    public var unit: String?
    public var display: String?
    public var position: Int?
    public var recipeId: String?
}

public struct SeedTimerDTO: Sendable, Codable {
    public var seconds: Int
    public var label: String
}

public struct SeedStepDTO: Sendable, Codable {
    public var id: String
    public var position: Int?
    public var text: String
    public var timers: [SeedTimerDTO]?
    public var recipeId: String?
}

public struct SeedPhotoKeysDTO: Sendable, Codable {
    public var original: String?
    public var large1024: String?
    public var thumb: String?
}

public struct SeedRecipeDTO: Sendable, Codable {
    public var id: String
    public var updatedAt: String?
    public var deviceId: String?
    public var deleted: Bool?
    public var entity: String?
    public var title: String
    public var description: String?
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var rating: Double?
    public var source: String?
    public var sourceUrl: String?
    public var categories: [String]?
    public var householdId: String?
    public var photoKeys: SeedPhotoKeysDTO?
    public var ingredients: [SeedIngredientDTO]?
    public var steps: [SeedStepDTO]?
}

// MARK: - Loader

/// Result of a seed load, safe to pass across actors.
public struct SeedLoadResult: Sendable {
    public var loaded: Int
    public var skipped: Int
    public init(loaded: Int, skipped: Int) {
        self.loaded = loaded
        self.skipped = skipped
    }
}

@MainActor
public final class SeedLoader {
    private let deviceId: String
    private let iso: ISO8601DateFormatter

    public init(deviceId: String) {
        self.deviceId = deviceId
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        self.iso = f
    }

    /// Load every `recipe-*.json` in `seedDirectory` into `context`.
    /// Idempotent: existing ids are skipped (counted as `skipped`).
    /// Never throws — returns counts; callers can retry or show demo data.
    public func loadSeeds(from seedDirectory: URL, into context: ModelContext) -> SeedLoadResult {
        var loaded = 0
        var skipped = 0
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: seedDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.lastPathComponent.hasPrefix("recipe-") }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let dto = try? JSONDecoder().decode(SeedRecipeDTO.self, from: data)
            else { skipped += 1; continue }
            if (try? context.fetch(FetchDescriptor<Recipe>(predicate: #Predicate { $0.id == dto.id })))?.isEmpty == false {
                skipped += 1
                continue
            }
            insert(dto: dto, into: context)
            loaded += 1
        }
        try? context.save()
        return SeedLoadResult(loaded: loaded, skipped: skipped)
    }

    /// Bundle-based convenience: looks for a `Seed` resource folder or
    /// flat `recipe-*.json` files in the main bundle. Returns (0,0) when
    /// absent (e.g. unit tests) instead of crashing.
    public func loadBundledSeeds(into context: ModelContext) -> SeedLoadResult {
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Seed"),
           (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil
        {
            return loadSeeds(from: dir, into: context)
        }
        // Flat fallback: recipe-*.json copied as individual bundle resources
        // (XcodeGen adds them at the bundle root, not in a Seed/ subfolder).
        if let root = Bundle.main.resourceURL {
            return loadSeeds(from: root, into: context)
        }
        return SeedLoadResult(loaded: 0, skipped: 0)
    }

    // MARK: - Private

    private func insert(dto: SeedRecipeDTO, into context: ModelContext) {
        let updatedAt = dto.updatedAt.flatMap { iso.date(from: $0) } ?? Date()
        let recipe = Recipe(
            id: dto.id,
            householdId: dto.householdId ?? "hh-demo",
            title: dto.title,
            recipeDescription: dto.description ?? "",
            servings: dto.servings ?? 4,
            prepMinutes: dto.prepMinutes,
            cookMinutes: dto.cookMinutes,
            rating: dto.rating,
            source: dto.source ?? "",
            sourceUrl: dto.sourceUrl ?? "",
            categories: dto.categories ?? [],
            photoOriginal: dto.photoKeys?.original,
            photoLarge1024: dto.photoKeys?.large1024,
            photoThumb: dto.photoKeys?.thumb,
            updatedAt: updatedAt,
            deviceId: dto.deviceId ?? "seed",
            tombstoned: dto.deleted ?? false
        )
        context.insert(recipe)
        for ing in dto.ingredients ?? [] {
            let m = Ingredient(
                id: ing.id,
                recipeId: dto.id,
                name: ing.name,
                quantity: ing.quantity,
                unit: ing.unit ?? "",
                display: ing.display ?? "",
                position: ing.position ?? 0,
                updatedAt: updatedAt,
                deviceId: dto.deviceId ?? "seed"
            )
            m.recipe = recipe
            context.insert(m)
        }
        for st in dto.steps ?? [] {
            let timers = (st.timers ?? []).map { StepTimer(seconds: $0.seconds, label: $0.label) }
            let m = Step(
                id: st.id,
                recipeId: dto.id,
                position: st.position ?? 0,
                text: st.text,
                timers: timers,
                updatedAt: updatedAt,
                deviceId: dto.deviceId ?? "seed"
            )
            m.recipe = recipe
            context.insert(m)
        }
    }
}
