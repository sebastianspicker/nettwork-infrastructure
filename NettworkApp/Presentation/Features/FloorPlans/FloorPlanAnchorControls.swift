import FeatureContracts
import Foundation
import NetworkModel
import SwiftUI

struct FloorPlanAnchorControls: View {
    @Binding var selectedObject: InventorySearchResult?
    @Binding var rawObjectID: String
    let canChooseObject: Bool
    let permitsPrivilegedAction: Bool
    let isActionInFlight: Bool
    let chooseObject: () -> Void
    let addSelected: () -> Void
    let addByIdentifier: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: NettworkSpacing.small) {
            adaptiveLayout {
                Button(selectedObject == nil ? "Choose object" : "Change object", action: chooseObject)
                    .disabled(!canChooseObject)
                if let selectedObject {
                    VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                        Label(selectedObject.title, systemImage: selectedObject.kind.symbolName)
                        Text(selectedObject.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Add anchor", action: addSelected)
                    .keyboardShortcut("a", modifiers: [.command])
                    .disabled(selectedObject == nil || !permitsPrivilegedAction || isActionInFlight)
                    .accessibilityIdentifier("floor-plan.add-anchor")
            }
            DisclosureGroup("Advanced: enter opaque object identifier") {
                adaptiveLayout {
                    TextField("Object UUID", text: $rawObjectID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("floor-plan.new-anchor-object")
                    Button("Add by identifier", action: addByIdentifier)
                        .disabled(!hasValidIdentifier || !permitsPrivilegedAction || isActionInFlight)
                }
            }
            .font(.footnote)
        }
        .padding(.horizontal)
    }

    private var hasValidIdentifier: Bool {
        UUID(uuidString: rawObjectID) != nil
    }

    private var adaptiveLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NettworkSpacing.small))
            : AnyLayout(HStackLayout(spacing: NettworkSpacing.small))
    }
}

struct FloorPlanAnchorPositionEditor: View {
    let anchor: FloorPlanAnchor
    let label: String
    let save: (Double, Double) -> Void
    @State private var horizontalPercent: Int
    @State private var verticalPercent: Int
    @Environment(\.dismiss) private var dismiss

    init(anchor: FloorPlanAnchor, label: String, save: @escaping (Double, Double) -> Void) {
        self.anchor = anchor
        self.label = label
        self.save = save
        _horizontalPercent = State(initialValue: Int((anchor.x * 100).rounded()))
        _verticalPercent = State(initialValue: Int((anchor.y * 100).rounded()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    Stepper(value: $horizontalPercent, in: 0...100) {
                        LabeledContent("Across", value: "\(horizontalPercent)%")
                    }
                    Stepper(value: $verticalPercent, in: 0...100) {
                        LabeledContent("Down", value: "\(verticalPercent)%")
                    }
                }
            }
            .navigationTitle("Move \(label)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Stage move") {
                        save(Double(horizontalPercent) / 100, Double(verticalPercent) / 100)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct FloorPlanAnchorRemovalDialog: ViewModifier {
    @Binding var anchor: FloorPlanAnchor?
    let label: (FloorPlanAnchor) -> String
    let remove: (FloorPlanAnchor) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove this anchor?",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: anchor
        ) { anchor in
            Button("Remove anchor", role: .destructive) { remove(anchor) }
                .accessibilityIdentifier("floor-plan.remove-anchor.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("floor-plan.remove-anchor.cancel")
        } message: { anchor in
            Text(
                "Remove the anchor for \(label(anchor))? "
                    + "This stages a work order; it does not change the authoritative floor plan directly."
            )
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { anchor != nil },
            set: { if !$0 { anchor = nil } }
        )
    }
}

extension View {
    func floorPlanAnchorRemovalDialog(
        anchor: Binding<FloorPlanAnchor?>,
        label: @escaping (FloorPlanAnchor) -> String,
        remove: @escaping (FloorPlanAnchor) -> Void
    ) -> some View {
        modifier(FloorPlanAnchorRemovalDialog(anchor: anchor, label: label, remove: remove))
    }
}
