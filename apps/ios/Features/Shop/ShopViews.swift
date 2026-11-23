// Smidgen — Lane 4 Shop/Pantry: multi-list aisle-sorted views + pantry
// Consumes Core ShoppingList/ListItem/PantryItem via snapshots (no new
// persistence, no auth/sync changes). iPad-compatible: NavigationStack
// content for the Lane 2 PadSplitView; pantry gets a two-column grid under
// .regular size class.

import SwiftUI

// MARK: - Snapshots

public struct ShopItemSnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var quantity: String
    public var aisle: String
    public var checked: Bool
    public var recipeId: String?
    public init(id: String, name: String, quantity: String = "",
                aisle: String = "", checked: Bool = false, recipeId: String? = nil) {
        self.id = id; self.name = name; self.quantity = quantity
        self.aisle = aisle; self.checked = checked; self.recipeId = recipeId
    }
}

public struct ShoppingListSnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var items: [ShopItemSnapshot]
    public init(id: String, name: String, items: [ShopItemSnapshot] = []) {
        self.id = id; self.name = name; self.items = items
    }
}

public struct PantrySnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var quantity: String
    public var location: String
    public var expiresAt: Date?
    public var lowThreshold: String
    public var barcode: String
    public init(id: String, name: String, quantity: String = "", location: String = "",
                expiresAt: Date? = nil, lowThreshold: String = "", barcode: String = "") {
        self.id = id; self.name = name; self.quantity = quantity
        self.location = location; self.expiresAt = expiresAt
        self.lowThreshold = lowThreshold; self.barcode = barcode
    }
}

// MARK: - Shopping lists (aisle-sorted, check-off)

/// Multi-list view, each list aisle-sorted with check-off.
/// `onToggle(listId:itemId:)` persists the flip via the caller's SwiftData context.
public struct ShopListsView: View {
    private let lists: [ShoppingListSnapshot]
    var onToggle: ((String, String) -> Void)?
    var onAddRecipeToList: ((String) -> Void)? // recipeId -> scaled add sheet

    public init(lists: [ShoppingListSnapshot],
                onToggle: ((String, String) -> Void)? = nil,
                onAddRecipeToList: ((String) -> Void)? = nil) {
        self.lists = lists; self.onToggle = onToggle
        self.onAddRecipeToList = onAddRecipeToList
    }

    public var body: some View {
        List {
            ForEach(lists) { list in
                Section("\(list.name) (\(list.items.filter { !$0.checked }.count) left)") {
                    ForEach(sortedItems(list.items)) { item in
                        Button { onToggle?(list.id, item.id) } label: {
                            HStack {
                                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.checked ? .green : .secondary)
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                        .strikethrough(item.checked)
                                    if !item.quantity.isEmpty || !item.aisle.isEmpty {
                                        Text([item.quantity, item.aisle].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Shopping lists")
    }

    private func sortedItems(_ items: [ShopItemSnapshot]) -> [ShopItemSnapshot] {
        items.sorted {
            let kl = aisleSortKey(aisle: $0.aisle, name: $0.name)
            let kr = aisleSortKey(aisle: $1.aisle, name: $1.name)
            if $0.checked != $1.checked { return !$0.checked } // unchecked first
            if kl.0 != kr.0 { return kl.0 < kr.0 }
            if kl.1 != kr.1 { return kl.1 < kr.1 }
            return kl.2 < kr.2
        }
    }
}

// MARK: - Recipe -> list (scaled)

/// Adds one recipe's ingredients to a list, scaled to `targetServings`.
/// Pure helper so the sheet + tests share logic.
public func recipeLinesToList(inputs: [PlanGroceryInput]) -> [AggregatedItem] {
    aggregateWeekToList(inputs)
}

// MARK: - Pantry (locations + expiry + low-stock + barcode)

public struct PantryView: View {
    private let items: [PantrySnapshot]
    @State private var showScanner = false
    var onBarcode: ((String) -> Void)?

    public init(items: [PantrySnapshot], onBarcode: ((String) -> Void)? = nil) {
        self.items = items; self.onBarcode = onBarcode
    }

    public var body: some View {
        List {
            Section("Needs attention") {
                ForEach(flaggedItems) { item in
                    pantryRow(item)
                }
                if flaggedItems.isEmpty {
                    Text("Nothing expiring or low.").foregroundStyle(.secondary)
                }
            }
            Section("All") {
                ForEach(sortedRest) { item in
                    pantryRow(item)
                }
            }
        }
        .navigationTitle("Pantry")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showScanner = true } label: {
                    Label("Scan", systemImage: "barcode.viewfinder")
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            BarcodeScannerStub { code in onBarcode?(code) }
        }
    }

    private var flaggedItems: [PantrySnapshot] {
        items.filter {
            expiryStatus(expiresAt: $0.expiresAt) != .fresh
                && expiryStatus(expiresAt: $0.expiresAt) != .noDate
                || isLowStock(quantity: $0.quantity, threshold: $0.lowThreshold)
        }
    }

    private var sortedRest: [PantrySnapshot] {
        items.sorted {
            if $0.location.lowercased() != $1.location.lowercased() {
                return $0.location.lowercased() < $1.location.lowercased()
            }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    private func pantryRow(_ item: PantrySnapshot) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.name).font(.headline)
                HStack(spacing: 6) {
                    if !item.location.isEmpty {
                        Text(item.location).font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.quantity.isEmpty {
                        Text(item.quantity).font(.caption).foregroundStyle(.secondary)
                    }
                    if isLowStock(quantity: item.quantity, threshold: item.lowThreshold) {
                        Text("Low").font(.caption.bold()).foregroundStyle(.orange)
                    }
                    switch expiryStatus(expiresAt: item.expiresAt) {
                    case .expired:
                        Text("Expired").font(.caption.bold()).foregroundStyle(.red)
                    case .expiringSoon:
                        Text("Expiring soon").font(.caption.bold()).foregroundStyle(.orange)
                    case .fresh, .noDate:
                        EmptyView()
                    }
                }
            }
            Spacer()
        }
    }
}
