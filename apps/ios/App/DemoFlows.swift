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

/// Resolves a stored photo value to a loadable remote URL.
///
/// Stored `photoThumb` values are relative R2 keys (e.g.
/// `photos/<id>/thumb.jpg`) and there is no public-URL resolver wired yet, so
/// those return nil and photos render as placeholders. Absolute http(s) URLs
/// pass through for forward-compat.
private func photoURL(forKey key: String?) -> URL? {
    guard let key, !key.isEmpty,
          let url = URL(string: key),
          url.scheme == "http" || url.scheme == "https"
    else { return nil }
    return url
}

// MARK: - Recipes tab (live list → detail → cook / add-to-list)

struct RecipeLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Recipe> { !$0.deleted },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil

    private var allCategories: [String] {
        Array(Set(recipes.flatMap { $0.categories })).sorted()
    }

    private var filtered: [Recipe] {
        // Single source of truth for search behavior — see LibrarySearch.swift.
        filterRecipes(recipes, filter: AdvancedFilter(
            query: searchText,
            categories: selectedCategory.map { [$0] } ?? []))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !allCategories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryChip(title: "All", selected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(allCategories, id: \.self) { cat in
                                categoryChip(title: cat, selected: selectedCategory == cat) {
                                    selectedCategory = (selectedCategory == cat) ? nil : cat
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
                Group {
                    if recipes.isEmpty {
                        VStack(spacing: 8) {
                            ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                                description: Text("Seeds load on first launch — airplane mode works."))
                            ActionsCTA()
                        }
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        List {
                            ForEach(filtered, id: \.id) { recipe in
                                NavigationLink {
                                    RecipeDetailView(recipe: recipe)
                                } label: {
                                    HStack(spacing: 12) {
                                        recipeThumb(for: recipe)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(recipe.title).font(.headline)
                                            Text(librarySubtitle(for: recipe))
                                                .font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .onDelete(perform: tombstone)
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.bottom, 90, for: .scrollContent)
                        .safeAreaPadding(.bottom, 8)
                        .accessibilityIdentifier("recipe-list")
                    }
                }
            }
            .navigationTitle("Recipes")
            .searchable(text: $searchText, prompt: "Search recipes")
            .toolbar(content: {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Menu(content: {
                        NavigationLink(destination: ClipView()) {
                            Text("Clip recipe URL")
                        }
                        NavigationLink(destination: OCRScanView()) {
                            Text("Scan cookbook (OCR)")
                        }
                    }, label: {
                        Image(systemName: "plus")
                            .accessibilityIdentifier("add-recipe-button")
                    })
                }
            })
        }
    }

    private func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-chip-\(title)")
    }

    private func recipeThumb(for recipe: Recipe) -> some View {
        Group {
            if let url = photoURL(forKey: recipe.photoThumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default:
                        Image(systemName: "fork.knife.circle.fill")
                            .resizable().scaledToFit().padding(8)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "fork.knife.circle.fill")
                    .resizable().scaledToFit().padding(8)
                    .frame(width: 52, height: 52)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func librarySubtitle(for recipe: Recipe) -> String {
        let n = recipe.ingredients.count, m = recipe.steps.count
        var parts = [
            n == 1 ? "1 ingredient" : "\(n) ingredients",
            m == 1 ? "1 step" : "\(m) steps",
        ]
        if let total = totalMinutes(for: recipe) { parts.append("\(total) min") }
        if recipe.servings > 0 {
            parts.append("Serves \(fractionDisplayString(for: recipe.servings))")
        }
        let cats = recipe.categories.prefix(2).joined(separator: " · ")
        if !cats.isEmpty { parts.append(cats) }
        return parts.joined(separator: " · ")
    }

    private func totalMinutes(for recipe: Recipe) -> Int? {
        switch (recipe.prepMinutes, recipe.cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    private func tombstone(at offsets: IndexSet) {
        for i in offsets {
            filtered[i].deleted = true
            // Sync is last-write-wins on updatedAt: bump it so this delete
            // tombstone beats a remote copy (mirrors applyMerge in LibraryViews).
            filtered[i].updatedAt = Date()
        }
        try? context.save()
    }
}

private struct ActionsCTA: View {
    var body: some View {
        VStack(spacing: 8) {
            NavigationLink("Clip a recipe URL") { ClipView() }
                .buttonStyle(.borderedProminent)
            NavigationLink("Scan a cookbook") { OCRScanView() }
                .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var context
    let recipe: Recipe
    @State private var addedMessage: String?
    @State private var checked: Set<String> = []
    @State private var servings: Double

    init(recipe: Recipe) {
        self.recipe = recipe
        _servings = State(initialValue: recipe.servings)
        _addedMessage = State(initialValue: nil)
    }

    private var sortedIngredients: [Ingredient] {
        recipe.ingredients.sorted(by: { $0.position < $1.position })
    }

    private var sortedSteps: [Step] {
        recipe.steps.sorted(by: { $0.position < $1.position })
    }

    private var totalMinutes: Int? {
        switch (recipe.prepMinutes, recipe.cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    var body: some View {
        List {
            // Photo hero
            Section {
                heroHeader
            }
            .listRowInsets(EdgeInsets())
            // Meta row
            Section {
                HStack(spacing: 12) {
                    Stepper("Serves \(servingsDisplay)", value: $servings, in: 1...24, step: 1)
                        .font(.subheadline)
                    Spacer()
                    if let total = totalMinutes {
                        Label("\(total) min", systemImage: "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let rating = recipe.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if !recipe.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(recipe.categories, id: \.self) { cat in
                                Text(cat).font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            Section("Ingredients (\(sortedIngredients.count))") {
                ForEach(sortedIngredients) { ing in
                    Button {
                        if checked.contains(ing.id) { checked.remove(ing.id) }
                        else { checked.insert(ing.id) }
                    } label: {
                        HStack {
                            Image(systemName: checked.contains(ing.id)
                                ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(checked.contains(ing.id) ? .green : .secondary)
                            Text(ing.display.isEmpty ? ing.name : ing.display)
                                .strikethrough(checked.contains(ing.id))
                                .foregroundStyle(checked.contains(ing.id) ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Steps (\(sortedSteps.count))") {
                ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Circle())
                        Text(step.text)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                NavigationLink {
                    CookModeView(
                        title: recipe.title,
                        baseServings: recipe.servings,
                        ingredients: recipe.ingredients.map {
                            CookModeView.IngredientSnapshot(id: $0.id, name: $0.name,
                                quantity: $0.quantity, unit: $0.unit)
                        },
                        steps: recipe.steps.map {
                            CookModeView.StepSnapshot(id: $0.id, position: $0.position, text: $0.text)
                        },
                        initialServings: servings)
                } label: {
                    Label("Cook", systemImage: "frying.pan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("cook-button")
                Button {
                    addToList()
                } label: {
                    Label("Add to shopping list", systemImage: "cart.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("add-to-list-button")
            }
            // Confirmation sits directly under the button that triggers it.
            if let addedMessage {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(addedMessage).foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("added-confirm")
                }
            }
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("recipe-detail-title")
    }

    private var servingsDisplay: String {
        fractionDisplayString(for: servings)
    }

    @ViewBuilder
    private var heroHeader: some View {
        if let url = photoURL(forKey: recipe.photoThumb) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(height: 220).clipped()
                default:
                    placeholderHero
                }
            }
        } else {
            placeholderHero
        }
    }

    private var placeholderHero: some View {
        ZStack {
            LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 140)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func addToList() {
        let deviceId = currentDeviceId()
        let inputs = recipe.ingredients.map { ing in
            PlanGroceryInput(name: ing.name, quantity: ing.quantity, unit: ing.unit,
                baseServings: recipe.servings, targetServings: servings, recipeId: recipe.id)
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
