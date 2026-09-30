import FeatureContracts
import NetworkModel
import SwiftUI

struct FloorPlanObjectPicker: View {
    @Bindable var model: InventoryExploreModel
    let onSelect: (InventorySearchResult) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Scope") {
                    Picker("Site", selection: $model.query.siteID) {
                        Text("All sites").tag(Optional<ObjectID>.none)
                        ForEach(model.siteOptions) { site in
                            Text(site.title).tag(Optional(site.id))
                        }
                    }
                    .onChange(of: model.query.siteID) { _, _ in
                        Task { await model.search() }
                    }
                }
                Section("Objects") {
                    if model.results.isEmpty {
                        FloorPlanObjectPickerState(state: model.state)
                    } else {
                        ForEach(model.results) { result in
                            Button {
                                onSelect(result)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                                        Text(result.title)
                                        Text(result.subtitle)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: result.kind.symbolName)
                                }
                            }
                            .accessibilityLabel("\(result.kind.title), \(result.title), \(result.subtitle)")
                        }
                    }
                }
            }
            .navigationTitle("Choose infrastructure")
            .searchable(text: $model.query.text, prompt: "Name, host, IP, MAC, rack, or port")
            .onSubmit(of: .search) { Task { await model.search() } }
            .task {
                await model.loadSiteOptions()
                await model.search()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct FloorPlanObjectPickerState: View {
    let state: InventoryPresentationState

    var body: some View {
        switch state {
        case .loading:
            NettworkLoadingState("Searching inventory")
        case .ready, .empty:
            NettworkEmptyState(
                "No matching infrastructure",
                systemImage: "magnifyingglass",
                message: "Adjust the site or search terms."
            )
        case .pending(let message):
            statusLabel(message, role: .pending)
        case .conflict(let message), .quarantined(let message):
            statusLabel(message, role: .conflict)
        case .offline(let message), .permissionDenied(let message), .unavailable(let message):
            statusLabel(message, role: .offline)
        }
    }

    private func statusLabel(_ message: String, role: NettworkStatusRole) -> some View {
        Label(message, systemImage: role.symbolName)
            .font(.footnote)
            .foregroundStyle(role.color)
    }
}
