import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

extension IPAMWorkspaceScreen {
    func stageSelectedAddressAssignment() {
        guard let address = filteredAddresses.first(where: { $0.id == assignmentAddressID }),
            let interface = selectedAssignmentInterface
        else { return }
        Task {
            await model.stageAddressAssignment(
                address: address,
                interface: interface,
                action: assignmentAction,
                primaryAddressID: assignmentPrimaryAddressID
            )
        }
    }

    var workOrderDetails: some View {
        Section {
            if let vrf = model.selectedVRF {
                LabeledContent("VRF scope", value: "\(vrf.name) · revision \(vrf.revision)")
                Text("Every mutation below is staged against this VRF revision. It cannot write authoritative IPAM data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a VRF before staging a request.").foregroundStyle(.secondary)
            }
            TextField("Work-order title", text: $model.draftTitle)
            TextField("Ticket", text: $model.ticketID)
            TextField("Notes", text: $model.draftNotes, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Label("Work-order request", systemImage: "doc.text")
        } footer: {
            Text("A title and ticket are required before any IPAM change can be staged.")
        }
    }

    var membershipStaging: some View {
        Section {
            Picker("Interface", selection: $membershipInterfaceID) {
                Text("Select an interface").tag(ObjectID?.none)
                ForEach(filteredInterfaces) { interface in
                    Text("\(interface.deviceName) · \(interface.name) (\(interface.mode.rawValue))")
                        .tag(interface.id as ObjectID?)
                }
            }
            Picker("VLAN", selection: $membershipVLANID) {
                Text("Select a VLAN").tag(ObjectID?.none)
                ForEach(filteredVLANs) { vlan in
                    Text("\(vlan.groupName) · \(vlan.number) \(vlan.name)").tag(vlan.id as ObjectID?)
                }
            }
            if let interface = selectedMembershipInterface {
                membershipModeExplanation(interface)
            }
            Picker("VLAN action", selection: $membershipAction) {
                ForEach(VLANMembershipStagingAction.allCases) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            Button("Stage VLAN membership set") {
                guard let interface = selectedMembershipInterface,
                    let vlan = filteredVLANs.first(where: { $0.id == membershipVLANID })
                else { return }
                Task { await model.stageVLANMembership(interface: interface, vlan: vlan, action: membershipAction) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedMembershipInterface == nil || membershipVLANID == nil || model.selectedVRF == nil || selectedMembershipInterface?.mode == .routed)
            .accessibilityHint("Stages a work-order request only; it does not change interface VLAN membership authoritatively.")
        } header: {
            Label("VLAN membership change", systemImage: "arrow.triangle.branch")
        } footer: {
            Text("The request carries the complete access, trunk, or native VLAN membership set for the selected interface.")
        }
    }

    @ViewBuilder fileprivate func membershipModeExplanation(_ interface: LogicalInterfaceSnapshot) -> some View {
        switch interface.mode {
        case .access:
            Label(
                "Access interface: add or replace its one native VLAN membership. "
                    + "Interface mode remains authoritative and unchanged.",
                systemImage: "arrow.down.to.line"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .trunk:
            Label(
                "Trunk interface: add or remove a VLAN, or switch its one native VLAN. "
                    + "The staged request carries the complete set.",
                systemImage: "arrow.triangle.branch"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .routed:
            Label("Routed interface: no access, trunk, or native VLAN membership can be staged with the current request contract.", systemImage: "nosign")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    var filteredVRFs: [VRFSnapshot] {
        model.vrfs.filter { matches($0.name) || prefixes(in: $0).contains { matches($0.cidr, $0.name) } }
    }

    var filteredAddresses: [IPAMAddressSnapshot] {
        model.addresses.filter { matches($0.address, $0.interfaceName ?? "", $0.vlanName ?? "") }
    }

    var filteredVLANs: [VLANSnapshot] {
        model.vlans.filter { matches($0.groupName, $0.name, String($0.number)) }
    }

    var filteredInterfaces: [LogicalInterfaceSnapshot] {
        model.interfaces.filter { matches($0.deviceName, $0.name, $0.mode.rawValue, $0.vlanSummary, $0.physicalPortLabel ?? "") }
    }

    fileprivate var selectedMembershipInterface: LogicalInterfaceSnapshot? {
        filteredInterfaces.first { $0.id == membershipInterfaceID }
    }

    var selectedAssignmentInterface: LogicalInterfaceSnapshot? {
        filteredInterfaces.first { $0.id == assignmentInterfaceID }
    }

    var selectedAssignmentAddressID: String? {
        guard let address = filteredAddresses.first(where: { $0.id == assignmentAddressID }),
            case let .string(addressID) = address.resourceKey
        else { return nil }
        return addressID
    }

    func stagePrefixRemoval(_ prefix: IPAMPrefixSnapshot) {
        Task { await model.stagePrefixRemoval(prefix) }
    }

    var pendingPrefixRemovalDialog: Binding<Bool> {
        Binding(
            get: { pendingPrefixRemoval != nil },
            set: { if !$0 { pendingPrefixRemoval = nil } }
        )
    }

    func ipamStateStatus(_ state: InventoryPresentationState) -> String {
        switch state {
        case .loading: "Loading IPAM workspace state."
        case .ready: "IPAM workspace state is ready."
        case .empty: "No IPAM records are available."
        case .offline(let message), .pending(let message), .conflict(let message),
            .quarantined(let message), .permissionDenied(let message), .unavailable(let message):
            message
        }
    }

    var groupedVLANs: [VLANGroupPresentation] {
        Dictionary(grouping: filteredVLANs, by: \.groupName)
            .map { VLANGroupPresentation(name: $0.key, vlans: $0.value.sorted { $0.number < $1.number }) }
            .sorted { $0.name < $1.name }
    }

    func prefixes(in vrf: VRFSnapshot) -> [IPAMPrefixSnapshot] {
        model.prefixes.filter { $0.vrfID == vrf.id && matches($0.cidr, $0.name, $0.reservedSummary) }
    }

    fileprivate func matches(_ values: String...) -> Bool {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    fileprivate func addressWorkflowState(_ address: IPAMAddressSnapshot) -> IPAMWorkflowState {
        if address.isConflicted { return .conflicting }
        if address.isPending { return .pending }
        if address.isPlanned { return .planned }
        return .authoritative
    }

    func workflowState(_ vrf: VRFSnapshot) -> IPAMWorkflowState {
        if vrf.isConflicted { return .conflicting }
        if vrf.isPending { return .pending }
        if vrf.isPlanned { return .planned }
        return .authoritative
    }

    func workflowState(_ prefix: IPAMPrefixSnapshot) -> IPAMWorkflowState {
        if prefix.isConflicted { return .conflicting }
        if prefix.isPending { return .pending }
        if prefix.isPlanned { return .planned }
        return .authoritative
    }

    func workflowState(_ vlan: VLANSnapshot) -> IPAMWorkflowState {
        if vlan.isConflicted { return .conflicting }
        if vlan.isPending { return .pending }
        if vlan.isPlanned { return .planned }
        return .authoritative
    }

    func workflowState(_ interface: LogicalInterfaceSnapshot) -> IPAMWorkflowState {
        if interface.isConflicted { return .conflicting }
        if interface.isPending { return .pending }
        if interface.isPlanned { return .planned }
        return .authoritative
    }
}

struct IPAMWorkflowBadge: View {
    let state: IPAMWorkflowState

    var body: some View {
        Label(state.rawValue, systemImage: state.symbolName)
            .font(.caption2)
            .foregroundStyle(state.tint)
            .accessibilityLabel(state.rawValue)
    }
}

@ViewBuilder
func IPAMPresentationStateMessage(state: InventoryPresentationState) -> some View {
    switch state {
    case .loading, .ready:
        EmptyView()
    case .empty:
        ContentUnavailableView("No IPAM records", systemImage: "network", description: Text("No VRFs or prefixes are available in this workspace."))
    case .pending(let message):
        Label(message, systemImage: IPAMWorkflowState.pending.symbolName)
            .foregroundStyle(IPAMWorkflowState.pending.tint)
    case .conflict(let message):
        Label(message, systemImage: IPAMWorkflowState.conflicting.symbolName)
            .foregroundStyle(IPAMWorkflowState.conflicting.tint)
    case .offline(let message), .unavailable(let message), .quarantined(let message), .permissionDenied(let message):
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
    }
}
