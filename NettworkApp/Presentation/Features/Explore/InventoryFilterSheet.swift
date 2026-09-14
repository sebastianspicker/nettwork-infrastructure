import NetworkModel
import SwiftUI

struct InventoryFilterSheet: View {
    let model: InventoryExploreModel
    let identifierPrefix: String
    @Environment(\.dismiss) private var dismiss
    @State private var kinds: Set<InventoryObjectKind>
    @State private var siteID: ObjectID?

    init(model: InventoryExploreModel, identifierPrefix: String) {
        self.model = model
        self.identifierPrefix = identifierPrefix
        _kinds = State(initialValue: model.query.kinds)
        _siteID = State(initialValue: model.query.siteID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Site", selection: $siteID) {
                        Text("All sites").tag(Optional<ObjectID>.none)
                        ForEach(model.siteOptions) { site in
                            Text(site.title).tag(Optional(site.id))
                        }
                    }
                    .accessibilityIdentifier("\(identifierPrefix).site-filter")
                }
                Section {
                    ForEach(InventoryObjectKind.allCases) { kind in
                        Toggle(isOn: kindBinding(kind)) {
                            Label(kind.title, systemImage: kind.symbolName)
                        }
                        .accessibilityIdentifier("\(identifierPrefix).filter.\(kind.rawValue)")
                    }
                } header: {
                    Text("Object types")
                } footer: {
                    Text("With no types selected, all inventory types are included.")
                }
                Section {
                    Button("Clear filters") {
                        kinds = []
                        siteID = nil
                    }
                    .disabled(kinds.isEmpty && siteID == nil)
                    .accessibilityIdentifier("\(identifierPrefix).clear-filters")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Filter inventory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.query.kinds = kinds
                        model.query.siteID = siteID
                        Task { await model.search() }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("\(identifierPrefix).apply-filters")
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 380, idealWidth: 440, minHeight: 520)
        #endif
    }

    private func kindBinding(_ kind: InventoryObjectKind) -> Binding<Bool> {
        Binding(
            get: { kinds.contains(kind) },
            set: { included in
                if included { kinds.insert(kind) } else { kinds.remove(kind) }
            })
    }
}
