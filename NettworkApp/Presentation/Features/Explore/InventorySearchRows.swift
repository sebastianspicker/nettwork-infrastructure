import NetworkModel
import SwiftUI

struct InventorySearchStateRow: View {
    let state: InventoryPresentationState

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Searching local inventory")
        case .ready, .empty:
            Label("No matching inventory objects", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        case .offline(let reason), .permissionDenied(let reason), .unavailable(let reason):
            stateLabel(reason, role: .offline)
        case .pending(let reason):
            stateLabel(reason, role: .pending)
        case .conflict(let reason), .quarantined(let reason):
            stateLabel(reason, role: .conflict)
        }
    }

    private func stateLabel(_ message: String, role: NettworkStatusRole) -> some View {
        Label(message, systemImage: role.symbolName)
            .foregroundStyle(role.color)
    }
}

struct InventoryExploreScreen: View {
    @Bindable var model: InventoryExploreModel
    @State private var filtersPresented = false

    var body: some View {
        List {
            historySections
            Section {
                if model.results.isEmpty {
                    InventorySearchStateRow(state: model.state)
                } else {
                    inventoryLinks(model.results)
                }
            } header: {
                Text("Results · \(model.results.count)")
            } footer: {
                Text("Search by asset, hostname, address, cable, rack, or port.")
            }
        }
        .navigationTitle("Inventory")
        .searchable(text: $model.query.text, prompt: "Search inventory")
        .onSubmit(of: .search) { Task { await model.search() } }
        .task {
            await model.loadHistory()
            await model.loadSiteOptions()
        }
        .task(id: model.query.text) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await model.search()
            } catch {}
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    filtersPresented = true
                } label: {
                    Label("Filters", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityValue(hasFilters ? "Filters active" : "All inventory")
                .accessibilityIdentifier("inventory.filters")
            }
        }
        .sheet(isPresented: $filtersPresented) {
            InventoryFilterSheet(model: model, identifierPrefix: "inventory")
        }
        .accessibilityIdentifier("inventory.results")
    }

    private var hasFilters: Bool { !model.query.kinds.isEmpty || model.query.siteID != nil }

    @ViewBuilder
    private var historySections: some View {
        if model.query.text.isEmpty && !hasFilters {
            if !model.favoriteResults.isEmpty {
                Section("Favorites") { inventoryLinks(model.favoriteResults) }
            }
            if !model.recentResults.isEmpty {
                Section("Recent") { inventoryLinks(model.recentResults) }
            }
        }
    }

    private func inventoryLinks(_ results: [InventorySearchResult]) -> some View {
        ForEach(results) { result in
            NavigationLink(value: AppRoute.object(result.id.rawValue)) {
                Label {
                    VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                        Text(result.title).fontWeight(.medium)
                        Text(result.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                } icon: {
                    Image(systemName: result.kind.symbolName).foregroundStyle(Color.nettworkAccent)
                }
                .padding(.vertical, NettworkSpacing.xSmall)
            }
            .accessibilityLabel("\(result.kind.title), \(result.title), \(result.subtitle)")
        }
    }
}
