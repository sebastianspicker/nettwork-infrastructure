import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension IPAMWorkspaceModel {
    func stageAddressAssignment(
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        action: AddressAssignmentStagingAction,
        primaryAddressID: String?
    ) async {
        guard let context = addressAssignmentContext(address: address, interface: interface),
            let desired = desiredAddressAssignments(
                address: address,
                interface: interface,
                action: action,
                primaryAddressID: primaryAddressID,
                current: context.current,
                addressID: context.addressID
            )
        else { return }
        await stage(
            IPAMWorkOrderRequest(
                title: draftTitle,
                ticketID: ticketID,
                notes: draftNotes,
                perVRFRevisionKey: .object(context.vrf.id),
                operation: .addressAssignment(
                    InterfaceAddressAssignmentSet(
                        revisionVRF: context.vrf.value,
                        interfaceID: interface.id,
                        currentAssignments: context.current,
                        desiredAssignments: desired.assignments,
                        primaryAddressID: desired.primaryAddressID
                    ))
            )
        )
    }

    private func addressAssignmentContext(
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot
    ) -> (vrf: VRFSnapshot, addressID: String, current: [IPAddressAssignment])? {
        guard let vrf = selectedVRF else {
            state = .unavailable("Select a VRF before staging an address assignment.")
            return nil
        }
        guard !address.isConflicted else {
            state = .conflict("This address has unresolved conflicts. Resolve them before staging a new assignment.")
            return nil
        }
        guard IPAddress(parsing: address.address) != nil else {
            validateAddress(address)
            state = .conflict("The address failed validation and cannot be staged.")
            return nil
        }
        guard case let .string(addressID) = address.resourceKey else {
            state = .conflict("The selected address does not have its authoritative record name.")
            return nil
        }
        let current = interface.addressAssignments
        guard current.allSatisfy({ $0.isActive && $0.interfaceID == interface.id }) else {
            state = .conflict("The interface assignment snapshot is incomplete. Refresh before staging this change.")
            return nil
        }
        return (vrf, addressID, current)
    }

    private func desiredAddressAssignments(
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        action: AddressAssignmentStagingAction,
        primaryAddressID: String?,
        current: [IPAddressAssignment],
        addressID: String
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        switch action {
        case .addSecondary:
            return addSecondaryAddressAssignment(
                current: current,
                address: address,
                interface: interface,
                addressID: addressID,
                primaryAddressID: primaryAddressID
            )
        case .makePrimary:
            return makePrimaryAddressAssignment(current: current, address: address, interface: interface, addressID: addressID)
        case .unassign:
            return unassignAddressAssignment(current: current, addressID: addressID, primaryAddressID: primaryAddressID)
        }
    }

    private func addSecondaryAddressAssignment(
        current: [IPAddressAssignment],
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        addressID: String,
        primaryAddressID: String?
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard !current.contains(where: { $0.addressID == addressID }), address.assignments.isEmpty, let primaryAddressID else {
            state = .unavailable("Choose an unassigned address and the existing primary address before adding a secondary assignment.")
            return nil
        }
        return normalizedAssignments(current + [IPAddressAssignment(addressID: addressID, interfaceID: interface.id)], primaryAddressID: primaryAddressID)
    }

    private func makePrimaryAddressAssignment(
        current: [IPAddressAssignment],
        address: IPAMAddressSnapshot,
        interface: LogicalInterfaceSnapshot,
        addressID: String
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard address.assignments.isEmpty || current.contains(where: { $0.addressID == addressID }) else {
            state = .unavailable("An address assigned to another interface cannot be added to this relationship set.")
            return nil
        }
        let desired =
            current.contains(where: { $0.addressID == addressID })
            ? current : current + [IPAddressAssignment(addressID: addressID, interfaceID: interface.id)]
        return normalizedAssignments(desired, primaryAddressID: addressID)
    }

    private func unassignAddressAssignment(
        current: [IPAddressAssignment],
        addressID: String,
        primaryAddressID: String?
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard current.contains(where: { $0.addressID == addressID }) else {
            state = .unavailable("The selected address is not assigned to this interface.")
            return nil
        }
        return normalizedAssignments(current.filter { $0.addressID != addressID }, primaryAddressID: primaryAddressID)
    }

    private func normalizedAssignments(
        _ assignments: [IPAddressAssignment],
        primaryAddressID: String?
    ) -> (assignments: [IPAddressAssignment], primaryAddressID: String?)? {
        guard (assignments.isEmpty && primaryAddressID == nil) || assignments.contains(where: { $0.addressID == primaryAddressID }) else {
            state = .unavailable("Choose exactly one primary address for the complete desired assignment set.")
            return nil
        }
        return (
            assignments.map { assignment in
                var value = assignment
                value.isPrimary = value.addressID == primaryAddressID
                return value
            }, primaryAddressID
        )
    }
}
