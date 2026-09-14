import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct IPAMWorkspaceScreen: View {
    @Bindable var model: IPAMWorkspaceModel
    let focusedObject: InventorySearchResult?
    let showsPageHeader: Bool

    @State var assignmentAddressID: ObjectID?
    @State var assignmentInterfaceID: ObjectID?
    @State var assignmentAction: AddressAssignmentStagingAction = .makePrimary
    @State var assignmentPrimaryAddressID: String?
    @State var membershipInterfaceID: ObjectID?
    @State var membershipVLANID: ObjectID?
    @State var membershipAction: VLANMembershipStagingAction = .add
    @State var pendingPrefixRemoval: IPAMPrefixSnapshot?
    let statusAnnouncer: any AccessibilityStatusAnnouncing

    @MainActor init(
        model: IPAMWorkspaceModel,
        focusedObject: InventorySearchResult? = nil,
        showsPageHeader: Bool = true,
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        self.model = model
        self.focusedObject = focusedObject
        self.showsPageHeader = showsPageHeader
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        List {
            if showsPageHeader {
                Section {
                    NettworkPageHeader(
                        "IP address management",
                        subtitle: "Review scoped address space and stage complete, revision-aware changes for approval.",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }
                .listRowSeparator(.hidden)
            }
            workflowLegend
            IPAMPresentationStateMessage(state: model.state)
            stagedWorkOrder
            vrfHierarchy
            prefixLayoutEditor
            addressAssignment
            vlanAndInterfacePresentation
            workOrderDetails
            membershipStaging
        }
        .navigationTitle("IPAM")
        .searchable(text: $model.searchText, prompt: "Prefix, address, VRF, VLAN, or interface")
        .task(id: focusedObject?.id) {
            guard await model.load(), !Task.isCancelled else { return }
            model.focus(on: focusedObject)
        }
        .confirmationDialog(
            "Stage prefix removal?",
            isPresented: pendingPrefixRemovalDialog,
            titleVisibility: .visible,
            presenting: pendingPrefixRemoval
        ) { prefix in
            Button("Stage removal", role: .destructive) {
                stagePrefixRemoval(prefix)
            }
            .accessibilityIdentifier("ipam.prefix-removal.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("ipam.prefix-removal.cancel")
        } message: { prefix in
            Text("Stage removal of \(prefix.cidr) from the complete \(prefix.vrfID.description) layout? No authoritative IPAM record is changed here.")
        }
        .onChange(of: model.state) { _, state in
            statusAnnouncer.announce(ipamStateStatus(state))
        }
    }
}
