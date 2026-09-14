import NetworkModel
import SwiftUI
import WorkspaceChangeControl

struct FloorPlanAnchorList: View {
    @Bindable var model: FloorPlanViewModel
    let authorization: OperationsAuthorization
    let objectDestination: (@MainActor (ObjectID) -> AnyView)?
    let onDone: () -> Void
    @State private var pendingMove: FloorPlanAnchor?

    var body: some View {
        NavigationStack {
            List {
                if model.filteredAnchors.isEmpty {
                    NettworkEmptyState(
                        "No anchors to show",
                        systemImage: "mappin.slash",
                        message: "Choose infrastructure from the floor-plan workspace to stage its first anchor."
                    )
                    .listRowSeparator(.hidden)
                } else {
                    Section("Anchors") {
                        ForEach(model.filteredAnchors) { anchor in
                            let label = model.labels[anchor.objectID] ?? anchor.objectID.description
                            anchorRow(anchor, label: label)
                        }
                    }
                }
            }
            .navigationTitle("Floor plan anchors")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
        .sheet(item: $pendingMove) { anchor in
            FloorPlanAnchorPositionEditor(
                anchor: anchor,
                label: model.labels[anchor.objectID] ?? anchor.objectID.description
            ) { x, y in
                Task {
                    await model.move(
                        anchor: anchor,
                        normalizedX: x,
                        normalizedY: y,
                        authorization: authorization
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func anchorRow(_ anchor: FloorPlanAnchor, label: String) -> some View {
        let coordinates = "x \(Int(anchor.x * 100))%, y \(Int(anchor.y * 100))%"
        HStack {
            if let objectDestination {
                NavigationLink {
                    objectDestination(anchor.objectID)
                } label: {
                    LabeledContent(label, value: coordinates)
                }
            } else {
                LabeledContent(label, value: coordinates)
            }
            Button {
                pendingMove = anchor
            } label: {
                Label("Move anchor", systemImage: "move.3d")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(!authorization.permitsPrivilegedAction || model.isAnchorActionInFlight)
            .accessibilityLabel("Move \(label)")
        }
    }
}
