// Smidgen — Lane 2 iOS Foundation
// apps/ios/App/SmidgenApp.swift
//
// Adaptive shell: iPhone = TabView (Recipes / Plan / Lists / More),
// iPad = NavigationSplitView sidebar + detail. iOS 17+.
//
// Rules: views never touch the network directly — they call
// `await syncCoordinator.sync()` (SyncEngine) from .task / .refreshable.
// Features/* stays stub-owned: tabs show Lane 2 list placeholders backed by
// SwiftData @Query so Lane 3+ can swap in real feature views.

import SwiftUI
import SwiftData

@main
struct SmidgenApp: App {
    /// Model types in the Lane 2 schema (passed as an array — the
    /// Scene `modelContainer(for:)` overload takes `[any PersistentModel.Type]`).
    static var modelTypes: [any PersistentModel.Type] {
        [Recipe.self,
         Ingredient.self,
         Step.self,
         ShoppingList.self,
         ListItem.self,
         PantryItem.self,
         Plan.self,
         Menu.self]
    }

    var body: some Scene {
        WindowGroup {
            AdaptiveShell()
        }
        // Offline-first store: local SwiftData is the source of truth.
        // CloudKit mirror arrives later via CloudKitMirrorStub (SyncEngine).
        .modelContainer(for: SmidgenApp.modelTypes)
    }
}

// MARK: - Adaptive shell

struct AdaptiveShell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular {
                PadSplitView()
            } else {
                PhoneTabView()
            }
            #else
            PhoneTabView()
            #endif
        }
        .task {
            // Airplane-mode demo: seeds load once, then sync when online.
            await SyncCoordinator.shared.seedIfNeeded(context: context)
        }
    }
}

// MARK: - iPhone: TabView

struct PhoneTabView: View {
    var body: some View {
        TabView {
            RecipeListPlaceholder()
                .tabItem { Label("Recipes", systemImage: "book.pages") }
            PlanListPlaceholder()
                .tabItem { Label("Plan", systemImage: "calendar") }
            ListsPlaceholder()
                .tabItem { Label("Lists", systemImage: "cart") }
            MorePlaceholder()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
    }
}

// MARK: - iPad: NavigationSplitView

struct PadSplitView: View {
    @Query private var recipes: [Recipe]
    @State private var selection: PadSection? = .recipes
    @State private var recipeSelectionId: String?

    var body: some View {
        NavigationSplitView {
            List(PadSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.icon)
                }
            }
            .navigationTitle("Smidgen")
        } content: {
            switch selection ?? .recipes {
            case .recipes:
                RecipeListPlaceholder(selectionId: $recipeSelectionId)
            case .plan:
                PlanListPlaceholder()
            case .lists:
                ListsPlaceholder()
            case .more:
                MorePlaceholder()
            }
        } detail: {
            if selection == .recipes,
               let id = recipeSelectionId,
               let recipe = recipes.first(where: { $0.id == id })
            {
                RecipeDetailPlaceholder(recipe: recipe)
            } else {
                ContentUnavailableView("Pick something", systemImage: "frying.pan",
                                       description: Text("Select an item to see details."))
            }
        }
    }
}

enum PadSection: String, Hashable, CaseIterable, Identifiable {
    case recipes, plan, lists, more
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recipes: return "Recipes"
        case .plan: return "Plan"
        case .lists: return "Lists"
        case .more: return "More"
        }
    }
    var icon: String {
        switch self {
        case .recipes: return "book.pages"
        case .plan: return "calendar"
        case .lists: return "cart"
        case .more: return "ellipsis.circle"
        }
    }
}

// MARK: - Placeholders (Lane 2 owns shell; Features/* owns real views)

/// Recipes tab / iPad content column. Live SwiftData, zero network.
struct RecipeListPlaceholder: View {
    @Query(filter: #Predicate<Recipe> { !$0.deleted },
           sort: [SortDescriptor(\Recipe.updatedAt, order: .reverse)])
    private var recipes: [Recipe]
    @Binding private var selectionId: String?

    init(selectionId: Binding<String?> = .constant(nil)) {
        _selectionId = selectionId
    }

    var body: some View {
        Group {
            if recipes.isEmpty {
                ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                    description: Text("Seeds load on first launch — airplane mode works."))
            } else {
                List(recipes, id: \.id, selection: $selectionId) { recipe in
                    VStack(alignment: .leading) {
                        Text(recipe.title).font(.headline)
                        Text("\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recipes")
        .refreshable { await SyncCoordinator.shared.sync() }
    }
}

struct RecipeDetailPlaceholder: View {
    let recipe: Recipe
    var body: some View {
        List {
            Section("Ingredients") {
                ForEach(recipe.ingredients.sorted(by: { $0.position < $1.position })) { ing in
                    Text(ing.display.isEmpty ? ing.name : ing.display)
                }
            }
            Section("Steps") {
                ForEach(recipe.steps.sorted(by: { $0.position < $1.position })) { step in
                    Text(step.text)
                }
            }
        }
        .navigationTitle(recipe.title)
    }
}

struct PlanListPlaceholder: View {
    @Query(filter: #Predicate<Plan> { !$0.deleted },
           sort: [SortDescriptor(\Plan.date)])
    private var plans: [Plan]
    var body: some View {
        Group {
            if plans.isEmpty {
                ContentUnavailableView("No plans yet", systemImage: "calendar",
                    description: Text("Meal plans you add will appear here, offline-first."))
            } else {
                List(plans) { plan in
                    HStack {
                        Text(plan.mealRaw.capitalized).font(.headline)
                        Spacer()
                        Text(plan.date, style: .date).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Plan")
        .refreshable { await SyncCoordinator.shared.sync() }
    }
}

struct ListsPlaceholder: View {
    @Query(filter: #Predicate<ShoppingList> { !$0.deleted },
           sort: [SortDescriptor(\ShoppingList.updatedAt, order: .reverse)])
    private var lists: [ShoppingList]
    var body: some View {
        Group {
            if lists.isEmpty {
                ContentUnavailableView("No lists yet", systemImage: "cart",
                    description: Text("Shopping lists sync across devices when online."))
            } else {
                List(lists) { list in
                    VStack(alignment: .leading) {
                        Text(list.name).font(.headline)
                        Text("\(list.items.count) items").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Lists")
        .refreshable { await SyncCoordinator.shared.sync() }
    }
}

struct MorePlaceholder: View {
    var body: some View {
        List {
            Section("Library") {
                Text("Pantry, menus and settings land here (Lane 3+).")
            }
            Section("Sync") {
                SyncStatusRow()
            }
        }
        .navigationTitle("More")
    }
}

// MARK: - Sync status + coordinator (views talk ONLY to this)

struct SyncStatusRow: View {
    @State private var status = "Offline-ready"
    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            Text(status).foregroundStyle(.secondary)
        }
        .task { status = await SyncCoordinator.shared.describe() }
    }
}

/// @MainActor bridge between SwiftUI views and the SyncEngine actor.
/// Owns deviceId, transport base URL, and one-shot seeding.
@MainActor
@Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private(set) var lastResult: String = "never synced"
    private var seeded = false

    func seedIfNeeded(context: ModelContext) async {
        guard !seeded else { return }
        seeded = true
        let count = (try? context.fetchCount(FetchDescriptor<Recipe>())) ?? 0
        if count == 0 {
            let loader = SeedLoader(deviceId: currentDeviceId())
            let res = loader.loadBundledSeeds(into: context)
            lastResult = "seeded \(res.loaded) recipes (offline demo)"
        }
    }

    func sync() async {
        // TODO(lane2-followup): wire APISyncTransport(baseURL:) + SwiftData
        // applyRemote once Lane 1 base URL is published. Until then this is
        // a no-op that keeps views network-free by construction.
        lastResult = "offline — no transport configured yet"
    }

    func describe() async -> String { lastResult }

    private func currentDeviceId() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }
}
