// Smidgen — PASS 2 demos
// apps/ios/App/DemoFlows.swift
//
// Wires the Lane 3/4 snapshot views (Clip/Caption/OCR, Plan, Shop, Cook)
// to live SwiftData so the three demo videos record the REAL app offline:
//   1. offline-launch — seeded recipes list with no backend configured.
//   2. ingest-save — OCRScanView: paste text → Parse → Save (fully local).
//   3. plan-to-list — PlanView week → "Add week to list" aggregates into an
//      aisle-sorted ShoppingList → check-off; cook mode reachable from detail.
//
// Accessibility identifiers (used by SmidgenUITests):
//   recipe-list, recipe-detail-title, cook-button, add-to-list-button,
//   added-confirm, plan-view, week-to-list-confirm, lists-view,
//   more-clip, more-caption, more-ocr (+ ocr-* ids in OCRScanView).

import SwiftUI
import SwiftData

// MARK: - Aisle guess (local heuristic for demo aggregation)

/// Keyword → canonical aisle (see ShopHelpers.canonicalAisles). Unknown → "".
func guessAisle(for name: String) -> String {
    let n = name.lowercased()
    let table: [(aisle: String, keys: [String])] = [
        ("produce", ["onion", "garlic", "tomato", "lettuce", "spinach", "carrot", "potato",
                     "avocado", "lemon", "lime", "herb", "basil", "cilantro", "parsley",
                     "mushroom", "pepper", "cucumber", "broccoli", "apple", "banana", "berry", "berries"]),
        ("bakery", ["bread", "baguette", "bun", "roll", "tortilla", "pita"]),
        ("dairy", ["milk", "cheese", "butter", "cream", "yogurt", "egg", "parmesan", "mozzarella"]),
        ("meat", ["chicken", "beef", "pork", "bacon", "sausage", "turkey"]),
        ("seafood", ["salmon", "tuna", "shrimp", "cod", "fish"]),
        ("frozen", ["frozen", "ice cream"]),
        ("canned", ["canned", "can ", "beans", "tomato paste", "broth", "stock"]),
        ("pasta", ["pasta", "spaghetti", "ramen", "noodle", "lasagna"]),
        ("baking", ["flour", "sugar", "baking", "yeast", "vanilla", "chocolate", "cocoa"]),
        ("spices", ["salt", "pepper", "cumin", "paprika", "oregano", "gochujang", "pesto",
                    "spice", "cinnamon", "curry", "masala"]),
        ("beverages", ["coffee", "tea", "juice", "wine"]),
        ("dry goods", ["rice", "oat", "cereal", "quinoa", "lentil"]),
    ]
    for (aisle, keys) in table where keys.contains(where: { n.contains($0) }) {
        return aisle
    }
    return ""
}

// MARK: - Recipes tab (live list → detail → cook / add-to-list)

struct RecipeLibraryView: View {
    @Query(filter: #Predicate<Recipe> { !$0.deleted },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]

    var body: some View {
        NavigationStack {
            Group {
                if recipes.isEmpty {
                    ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                        description: Text("Seeds load on first launch — airplane mode works."))
                } else {
                    List(recipes, id: \.id) { recipe in
                        NavigationLink {
                            RecipeDetailView(recipe: recipe)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(recipe.title).font(.headline)
                                Text("\(recipe.ingredients.count) ingredients · \(recipe.steps.count) steps")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("recipe-list")
                }
            }
            .navigationTitle("Recipes")
        }
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var context
    let recipe: Recipe
    @State private var addedMessage: String?

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
            Section {
                NavigationLink("Cook") {
                    CookModeView(
                        title: recipe.title,
                        baseServings: recipe.servings,
                        ingredients: recipe.ingredients.map {
                            CookModeView.IngredientSnapshot(id: $0.id, name: $0.name,
                                quantity: $0.quantity, unit: $0.unit)
                        },
                        steps: recipe.steps.map {
                            CookModeView.StepSnapshot(id: $0.id, position: $0.position, text: $0.text)
                        })
                }
                .accessibilityIdentifier("cook-button")
                Button("Add to shopping list") { addToList() }
                    .accessibilityIdentifier("add-to-list-button")
            }
            if let addedMessage {
                Section { Text(addedMessage).foregroundStyle(.green)
                    .accessibilityIdentifier("added-confirm") }
            }
        }
        .navigationTitle(recipe.title)
        .accessibilityIdentifier("recipe-detail-title")
    }

    private func addToList() {
        let deviceId = currentDeviceId()
        let inputs = recipe.ingredients.map { ing in
            PlanGroceryInput(name: ing.name, quantity: ing.quantity, unit: ing.unit,
                baseServings: recipe.servings, targetServings: nil, recipeId: recipe.id)
        }
        let lines = aggregateWeekToList(inputs)
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Shopping" && !$0.deleted
        }) {
            list = existing
        } else {
            list = ShoppingList(householdId: recipe.householdId, name: "Shopping", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            context.insert(ListItem(listId: list.id, name: line.name,
                quantity: line.totalQuantity.map { String(format: "%.2g", $0) } ?? "",
                aisle: guessAisle(for: line.name), deviceId: deviceId))
        }
        try? context.save()
        addedMessage = "Added \(lines.count) items to Shopping"
    }
}

// MARK: - Plan tab (live week → add week to list)

struct PlanTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Plan.date)]) private var plans: [Plan]
    @Query(sort: [SortDescriptor(\Menu.name)]) private var menus: [Menu]
    @Query private var recipes: [Recipe]
    @State private var confirm: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let confirm {
                    Text(confirm)
                        .font(.subheadline).foregroundStyle(.green)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("week-to-list-confirm")
                }
                PlanView(entries: entries, menus: menuSnapshots, onAddWeekToList: addWeekToList)
                    .accessibilityIdentifier("plan-view")
            }
        }
    }

    private var recipesById: [String: Recipe] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
    }

    private var entries: [PlanEntrySnapshot] {
        plans.filter { !$0.deleted }.map { plan in
            let recipe = plan.recipeId.flatMap { recipesById[$0] }
            return PlanEntrySnapshot(id: plan.id, date: plan.date,
                meal: plan.mealRaw, recipeId: plan.recipeId,
                recipeTitle: recipe?.title ?? (plan.note.isEmpty ? nil : plan.note),
                note: recipe == nil ? plan.note : "", servings: plan.servings)
        }
    }

    private var menuSnapshots: [MenuSnapshot] {
        menus.filter { !$0.deleted }.map {
            MenuSnapshot(id: $0.id, name: $0.name, entryCount: $0.entries.count)
        }
    }

    private func addWeekToList(_ weekStart: Date) {
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let weekPlans = plans.filter { !$0.deleted && $0.date >= weekStart && $0.date < weekEnd }
        var inputs: [PlanGroceryInput] = []
        for plan in weekPlans {
            guard let rid = plan.recipeId, let recipe = recipesById[rid] else { continue }
            for ing in recipe.ingredients {
                inputs.append(PlanGroceryInput(name: ing.name, quantity: ing.quantity,
                    unit: ing.unit, baseServings: recipe.servings,
                    targetServings: plan.servings, recipeId: rid))
            }
        }
        let lines = aggregateWeekToList(inputs)
        let deviceId = currentDeviceId()
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Weekly shop" && !$0.deleted
        }) {
            list = existing
            for item in list.items { context.delete(item) }
            list.items.removeAll()
        } else {
            list = ShoppingList(householdId: "hh-demo", name: "Weekly shop", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        confirm = "Added \(lines.count) items to Weekly shop"
    }
}

// MARK: - Lists tab (live aisle-sorted lists + check-off)

struct ListsTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\ShoppingList.updatedAt, order: .reverse)])
    private var lists: [ShoppingList]

    var body: some View {
        NavigationStack {
            Group {
                if lists.filter({ !$0.deleted }).isEmpty {
                    ContentUnavailableView("No lists yet", systemImage: "cart",
                        description: Text("Add a week to a list from the Plan tab."))
                } else {
                    ShopListsView(lists: snapshots, onToggle: toggle)
                        .accessibilityIdentifier("lists-view")
                }
            }
        }
    }

    private var snapshots: [ShoppingListSnapshot] {
        lists.filter { !$0.deleted }.map { list in
            ShoppingListSnapshot(id: list.id, name: list.name, items: list.items.map { item in
                ShopItemSnapshot(id: item.id, name: item.name, quantity: item.quantity,
                    aisle: item.aisle, checked: item.checked, recipeId: item.recipeId)
            })
        }
    }

    private func toggle(listId: String, itemId: String) {
        guard let item = (try? context.fetch(FetchDescriptor<ListItem>()))?.first(where: { $0.id == itemId }) else { return }
        item.checked.toggle()
        try? context.save()
    }
}

// MARK: - More tab (ingest entry points + sync status)

struct MoreTabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Add") {
                    NavigationLink("Clip recipe URL") { ClipView() }
                        .accessibilityIdentifier("more-clip")
                    NavigationLink("Import caption") { CaptionsImportView() }
                        .accessibilityIdentifier("more-caption")
                    NavigationLink("Scan cookbook (OCR)") { OCRScanView() }
                        .accessibilityIdentifier("more-ocr")
                }
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
}

// MARK: - Demo plan seeding (current week, idempotent)

enum DemoSeeds {
    static func weekStart(containing date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    /// Ensures Mon/Wed/Fri dinner plans exist for the current week so the
    /// plan→list video is deterministic. Skips entries already present.
    static func seedDemoPlans(context: ModelContext, deviceId: String) {
        let recipes = ((try? context.fetch(
            FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\Recipe.title)]))) ?? [])
            .filter { !$0.deleted }
        guard recipes.count >= 3 else { return }
        let cal = Calendar.current
        let start = weekStart(containing: Date())
        let picks: [(dayOffset: Int, meal: MealSlot)] = [
            (0, .dinner), (2, .dinner), (4, .dinner),
        ]
        let existing = (try? context.fetch(FetchDescriptor<Plan>())) ?? []
        for (i, pick) in picks.enumerated() {
            guard let day = cal.date(byAdding: .day, value: pick.dayOffset, to: start) else { continue }
            let recipe = recipes[i % recipes.count]
            let dayStart = cal.startOfDay(for: day)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? day
            let dup = existing.contains {
                !$0.deleted && $0.date >= dayStart && $0.date < dayEnd
                    && $0.mealRaw == pick.meal.rawValue && $0.recipeId == recipe.id
            }
            if dup { continue }
            context.insert(Plan(householdId: "hh-demo", date: day, meal: pick.meal,
                recipeId: recipe.id, servings: recipe.servings, deviceId: deviceId))
        }
        try? context.save()
    }
}

private func currentDeviceId() -> String {
    #if os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    #else
    return UUID().uuidString
    #endif
}
