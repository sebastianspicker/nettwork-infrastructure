import NetworkModel
import WorkspaceChangeControl

@MainActor
extension IPAMWorkspaceModel {
    func stageVLANMembership(
        interface: LogicalInterfaceSnapshot,
        vlan: VLANSnapshot,
        action: VLANMembershipStagingAction
    ) async {
        guard let vrf = selectedVRF else {
            state = .unavailable("Select a VRF before staging a VLAN membership request.")
            return
        }
        guard interface.mode != .routed else {
            state = .unavailable("Routed interfaces do not accept access, trunk, or native VLAN memberships.")
            return
        }
        let current = interface.vlanMemberships
        guard current.allSatisfy({ $0.isActive && $0.interfaceID == interface.id }) else {
            state = .conflict("The interface VLAN snapshot is incomplete. Refresh before staging this change.")
            return
        }
        guard
            let desired = desiredVLANMemberships(
                current: current,
                interface: interface,
                vlan: vlan,
                action: action
            )
        else { return }
        await stage(
            IPAMWorkOrderRequest(
                title: draftTitle,
                ticketID: ticketID,
                notes: draftNotes,
                perVRFRevisionKey: .object(vrf.id),
                operation: .vlanMembership(
                    InterfaceVLANMembershipSet(
                        revisionVRF: vrf.value,
                        interfaceID: interface.id,
                        currentMemberships: current,
                        desiredMemberships: desired
                    ))
            )
        )
    }

    func desiredVLANMemberships(
        current: [InterfaceVLANMembership],
        interface: LogicalInterfaceSnapshot,
        vlan: VLANSnapshot,
        action: VLANMembershipStagingAction
    ) -> [InterfaceVLANMembership]? {
        var desired = current
        switch action {
        case .add:
            if interface.mode == .access { return [InterfaceVLANMembership(interfaceID: interface.id, vlanID: vlan.id, isNative: true)] }
            if !desired.contains(where: { $0.vlanID == vlan.id }) { desired.append(InterfaceVLANMembership(interfaceID: interface.id, vlanID: vlan.id)) }
        case .remove:
            guard interface.mode == .trunk else {
                state = .unavailable("An access interface must retain its one native VLAN membership.")
                return nil
            }
            desired.removeAll { $0.vlanID == vlan.id }
        case .makeNative:
            if !desired.contains(where: { $0.vlanID == vlan.id }) { desired.append(InterfaceVLANMembership(interfaceID: interface.id, vlanID: vlan.id)) }
            desired = desired.map { membership in
                var value = membership
                value.isNative = value.vlanID == vlan.id
                return value
            }
        }
        return desired
    }
}
