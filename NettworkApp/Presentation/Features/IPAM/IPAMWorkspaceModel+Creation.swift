import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// An existing VLAN scope offered when a new VLAN is created.
struct IPAMVLANGroupChoice: Identifiable, Hashable {
    let id: ObjectID
    let name: String
}

/// Creation inputs are checked here with the same canonical-form rules as a
/// CSV import before a work-order draft is staged. The planner re-validates
/// every creation against the complete mirror at validation and completion.
@MainActor
extension IPAMWorkspaceModel {
    var vlanGroupChoices: [IPAMVLANGroupChoice] {
        Set(vlans.map { IPAMVLANGroupChoice(id: $0.groupID, name: $0.groupName) })
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    @discardableResult
    func stageNewVRF(name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return rejectCreation("Enter a VRF name before staging it.") }
        guard !vrfs.contains(where: { Self.sameName($0.name, name) }) else {
            return rejectCreation("A VRF named \(name) already exists.")
        }
        let vrf = VRF(name: name)
        return await stageCreation(.createVRF(vrf), scope: .object(vrf.id))
    }

    @discardableResult
    func stageNewAddress(_ text: String) async -> Bool {
        guard let vrf = selectedVRF else { return rejectCreation("Select a VRF before creating an address.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = IPAddress(parsing: text), address.description == text else {
            return rejectCreation("Enter a canonical IPv4 or IPv6 address, for example 192.0.2.10 or 2001:db8::1.")
        }
        guard prefixes.contains(where: { $0.vrfID == vrf.id && $0.value.contains(address) }) else {
            return rejectCreation("The address must fall inside a prefix of \(vrf.name). Stage that prefix first.")
        }
        return await stageCreation(.createAddressRecord(IPAddressRecord(vrfID: vrf.id, address: address)), scope: .object(vrf.id))
    }

    /// `groupID` selects an existing VLAN group; otherwise `newGroupName`
    /// names the group, reusing an existing group with the same name.
    @discardableResult
    func stageNewVLAN(number text: String, name: String, groupID: ObjectID?, newGroupName: String) async -> Bool {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...4094).contains(number) else {
            return rejectCreation("Enter a VLAN ID from 1 through 4094.")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return rejectCreation("Enter a VLAN name before staging it.") }
        guard let scope = vlanScope(groupID: groupID, newGroupName: newGroupName) else {
            return rejectCreation("Select a VLAN group or name a new one.")
        }
        guard !vlans.contains(where: { $0.groupID == scope.id && $0.number == number }) else {
            return rejectCreation("VLAN \(number) already exists in this group.")
        }
        let vlan = VLAN(groupID: scope.id, number: number, name: name)
        return await stageCreation(.createVLAN(vlan, newGroup: scope.newGroup), scope: .object(scope.id))
    }

    private func vlanScope(groupID: ObjectID?, newGroupName: String) -> (id: ObjectID, newGroup: VLANGroup?)? {
        if let groupID { return vlanGroupChoices.contains { $0.id == groupID } ? (groupID, nil) : nil }
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = vlanGroupChoices.first(where: { Self.sameName($0.name, name) }) { return (existing.id, nil) }
        let group = VLANGroup(name: name)
        return (group.id, group)
    }

    private func stageCreation(_ operation: IPAMWorkOrderOperation, scope: ResourceKey) async -> Bool {
        await stage(IPAMWorkOrderRequest(title: draftTitle, ticketID: ticketID, notes: draftNotes, perVRFRevisionKey: scope, operation: operation))
    }

    private func rejectCreation(_ message: String) -> Bool {
        state = .unavailable(message)
        return false
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
