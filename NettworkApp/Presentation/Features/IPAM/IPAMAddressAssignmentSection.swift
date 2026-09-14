import NetworkModel
import SwiftUI
import WorkspaceChangeControl

struct IPAMAddressAssignmentSection: View {
    @Bindable var model: IPAMWorkspaceModel
    let addresses: [IPAMAddressSnapshot]
    let interfaces: [LogicalInterfaceSnapshot]
    let selectedInterface: LogicalInterfaceSnapshot?
    let selectedAssignmentAddressID: String?
    @Binding var addressID: ObjectID?
    @Binding var interfaceID: ObjectID?
    @Binding var action: AddressAssignmentStagingAction
    @Binding var primaryAddressID: String?
    let stageAssignment: () -> Void

    var body: some View {
        Section {
            if let prefix = model.selectedPrefix {
                Label("Selected prefix: \(prefix.cidr)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                if addresses.isEmpty {
                    ContentUnavailableView(
                        "No matching addresses",
                        systemImage: "magnifyingglass",
                        description: Text("Select another prefix or clear the IPAM search.")
                    )
                } else {
                    IPAMAddressAssignmentControls(
                        model: model,
                        addresses: addresses,
                        interfaces: interfaces,
                        selectedInterface: selectedInterface,
                        selectedAssignmentAddressID: selectedAssignmentAddressID,
                        addressID: $addressID,
                        interfaceID: $interfaceID,
                        action: $action,
                        primaryAddressID: $primaryAddressID,
                        stageAssignment: stageAssignment
                    )
                }
            } else {
                ContentUnavailableView(
                    "Select a prefix",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Choose a prefix in the VRF hierarchy to search and stage address assignments.")
                )
            }
        } header: {
            Label("Address assignment", systemImage: "link")
        } footer: {
            Text("Choose an address and interface, then stage the complete relationship set for review.")
        }
    }
}

private struct IPAMAddressAssignmentControls: View {
    @Bindable var model: IPAMWorkspaceModel
    let addresses: [IPAMAddressSnapshot]
    let interfaces: [LogicalInterfaceSnapshot]
    let selectedInterface: LogicalInterfaceSnapshot?
    let selectedAssignmentAddressID: String?
    @Binding var addressID: ObjectID?
    @Binding var interfaceID: ObjectID?
    @Binding var action: AddressAssignmentStagingAction
    @Binding var primaryAddressID: String?
    let stageAssignment: () -> Void
    var body: some View {
        IPAMAddressRows(addresses: addresses, selectedAddressID: $addressID, validate: model.validateAddress)
        Picker("Address", selection: $addressID) {
            Text("Select an address").tag(ObjectID?.none)
            ForEach(addresses) {
                Text($0.address).tag($0.id as ObjectID?)
            }
        }
        Picker("Interface", selection: $interfaceID) {
            Text("Select an interface").tag(ObjectID?.none)
            ForEach(interfaces) {
                Text("\($0.deviceName) · \($0.name)").tag($0.id as ObjectID?)
            }
        }
        Picker("Assignment action", selection: $action) { ForEach(AddressAssignmentStagingAction.allCases) { Text($0.rawValue).tag($0) } }
        IPAMPrimaryAddressPicker(
            interface: selectedInterface,
            selectedAddressID: selectedAssignmentAddressID,
            action: action,
            primaryAddressID: $primaryAddressID
        )
        if let explanation = model.validationExplanation { Label(explanation, systemImage: "checkmark.shield").font(.footnote).foregroundStyle(.secondary) }
        Button("Stage address relationship set", action: stageAssignment)
            .buttonStyle(.borderedProminent)
            .disabled(addressID == nil || selectedInterface == nil || model.selectedVRF == nil)
            .accessibilityHint("Stages the complete interface assignment relationship set only; it does not change authoritative IPAM data.")
    }
}

private struct IPAMAddressRows: View {
    let addresses: [IPAMAddressSnapshot]
    @Binding var selectedAddressID: ObjectID?
    let validate: (IPAMAddressSnapshot) -> Void
    var body: some View {
        ForEach(addresses) { address in
            Button {
                selectedAddressID = address.id
                validate(address)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(address.address).font(.body.monospaced())
                        Spacer()
                        IPAMWorkflowBadge(
                            state: address.isConflicted
                                ? .conflicting
                                : address.isPending
                                    ? .pending
                                    : address.isPlanned ? .planned : .authoritative
                        )
                    }
                    Text("\(address.interfaceName ?? "Unassigned") · \(address.vlanName ?? "No VLAN")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("ipam.address.\(address.id.description)")
            .accessibilityAddTraits(selectedAddressID == address.id ? .isSelected : [])
            .listRowBackground(
                selectedAddressID == address.id
                    ? NettworkStatusRole.information.color.opacity(0.14)
                    : Color.clear
            )
        }
    }
}

private struct IPAMPrimaryAddressPicker: View {
    let interface: LogicalInterfaceSnapshot?
    let selectedAddressID: String?
    let action: AddressAssignmentStagingAction
    @Binding var primaryAddressID: String?
    var body: some View {
        if let interface {
            Picker("Primary address", selection: $primaryAddressID) {
                Text("Select the primary address").tag(String?.none)
                ForEach(
                    interface.addressAssignments.filter { assignment in
                        selectedAddressID.map { $0 != assignment.addressID } ?? true
                    }
                ) {
                    Text($0.addressID).tag($0.addressID as String?)
                }
            }
            .disabled(action == .makePrimary)
        }
    }
}
