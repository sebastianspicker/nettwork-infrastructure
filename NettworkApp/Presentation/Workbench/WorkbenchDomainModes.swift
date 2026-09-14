import SwiftUI

struct WorkbenchPhysicalMode: View {
    let details: InventoryObjectDetails?
    @Bindable var model: TopologyWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchScopeHeader(
                details: details,
                context: "Physical",
                isScoped: details.map { physicalKinds.contains($0.result.kind) } ?? false
            )
            TopologyWorkspaceScreen(model: model, focusedObject: details?.result, showsPageHeader: false)
        }
    }

    private var physicalKinds: Set<InventoryObjectKind> { [.rack, .device, .port, .cable] }
}

struct WorkbenchLogicalMode: View {
    let details: InventoryObjectDetails?
    @Bindable var model: IPAMWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchScopeHeader(
                details: details,
                context: "Logical",
                isScoped: details?.result.kind == .interface
            )
            IPAMWorkspaceScreen(model: model, focusedObject: details?.result, showsPageHeader: false)
        }
    }
}

private struct WorkbenchScopeHeader: View {
    let details: InventoryObjectDetails?
    let context: String
    let isScoped: Bool

    var body: some View {
        Group {
            if let details, isScoped {
                HStack(spacing: NettworkSpacing.standard) {
                    Label("Scoped to \(details.result.title)", systemImage: details.result.kind.symbolName)
                        .font(.subheadline.weight(.semibold))
                    Text(details.result.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    WorkbenchAuthorityBadge(result: details.result)
                }
                .accessibilityElement(children: .combine)
            } else if let details {
                NettworkNotice(
                    "Showing all \(context.lowercased()) records",
                    message:
                        "\(details.result.title) remains selected in the inspector, but its current records do not expose a reliable direct \(context.lowercased()) mapping."
                )
            } else {
                NettworkNotice(
                    "Choose an object for \(context.lowercased()) context",
                    message: "The workspace remains available, but it is not scoped to an inventory object."
                )
            }
        }
        .padding(.horizontal, NettworkSpacing.medium)
        .padding(.vertical, NettworkSpacing.small)
        .background(Color.nettworkSurface)
    }
}
