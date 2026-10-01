import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataProductionMutationPlanner {
    func applyIPAM(
        _ operation: PlannedIPAMOperation, workOrderID: ObjectID, operationIndex: Int, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        switch operation {
        case let .prefixLayout(vrf, expectedRevision, currentPrefixes, desiredPrefixes):
            try applyPrefixLayout(
                vrf: vrf, expectedRevision: expectedRevision, currentPrefixes: currentPrefixes, desiredPrefixes: desiredPrefixes,
                snapshot: &snapshot, changes: &changes
            )

        case let .addressAssignment(assignments):
            try applyAddressAssignments(assignments, snapshot: &snapshot, changes: &changes)

        case let .vlanMembership(memberships):
            try applyVLANMemberships(memberships, snapshot: &snapshot, changes: &changes)
        case .legacyAddressAssignment, .legacyVLANMembership:
            throw ProductionMutationPlannerError.legacyIntentRequiresReconciliation
        }
    }

    private func applyPrefixLayout(
        vrf: VRF, expectedRevision: Int, currentPrefixes: [Prefix], desiredPrefixes: [Prefix], snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        guard snapshot.vrfs[vrf.id] == vrf else {
            throw ProductionMutationPlannerError.missingIPAMObject(.object(vrf.id))
        }
        let mirroredCurrent = snapshot.prefixes.values
            .filter { $0.vrfID == vrf.id && $0.isActive }
            .sorted { $0.id < $1.id }
        guard mirroredCurrent == currentPrefixes.sorted(by: { $0.id < $1.id }) else {
            throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(vrf.id))
        }
        let result = try PrefixLayoutMutation.apply(prefixes: desiredPrefixes, to: vrf, expectedRevision: expectedRevision)
        let desiredIDs = Set(result.prefixes.map(\.id))
        for prefix in snapshot.prefixes.values where prefix.vrfID == vrf.id && !desiredIDs.contains(prefix.id) {
            snapshot.prefixes.removeValue(forKey: prefix.id)
            try changes.tombstone(prefix, recordType: "Prefix")
        }
        snapshot.vrfs[vrf.id] = result.vrf
        try changes.save(result.vrf, recordType: "VRF")
        for prefix in result.prefixes {
            snapshot.prefixes[prefix.id] = prefix
            try changes.save(prefix, recordType: "Prefix")
        }
    }

    private func applyAddressAssignments(_ assignments: InterfaceAddressAssignmentSet, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        let current = try validatedCurrentAssignments(assignments, snapshot: snapshot)
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let desired = sortedAssignments(assignments.desiredAssignments)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        for assignment in current {
            try removeAssignmentIfNeeded(assignment, desiredByID: desiredByID, interfaceID: assignments.interfaceID, snapshot: &snapshot, changes: &changes)
        }
        for assignment in desired {
            try saveAssignment(assignment, currentByID: currentByID, interfaceID: assignments.interfaceID, snapshot: &snapshot, changes: &changes)
        }
    }

    private func validatedCurrentAssignments(_ assignments: InterfaceAddressAssignmentSet, snapshot: Snapshot) throws -> [IPAddressAssignment] {
        guard snapshot.vrfs[assignments.revisionVRF.id] == assignments.revisionVRF,
            snapshot.interfaces[assignments.interfaceID]?.isActive == true
        else {
            throw ProductionMutationPlannerError.missingIPAMObject(.object(assignments.interfaceID))
        }
        let scopedAddressIDs = Set((assignments.currentAssignments + assignments.desiredAssignments).map(\.addressID))
        guard scopedAddressIDs.allSatisfy({ snapshot.addresses[$0]?.vrfID == assignments.revisionVRF.id }),
            isValid(assignments)
        else {
            throw ProductionMutationPlannerError.invalidIPAMRelationshipSet(.object(assignments.revisionVRF.id))
        }
        let current = sortedAssignments(
            snapshot.assignments.values.filter {
                $0.isActive && $0.interfaceID == assignments.interfaceID
            })
        guard current == sortedAssignments(assignments.currentAssignments) else {
            throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(assignments.interfaceID))
        }
        return current
    }

    private func removeAssignmentIfNeeded(
        _ assignment: IPAddressAssignment, desiredByID: [ObjectID: IPAddressAssignment], interfaceID: ObjectID, snapshot: inout Snapshot,
        changes: inout ChangeAccumulator
    ) throws {
        guard var address = snapshot.addresses[assignment.addressID],
            address.isActive,
            address.assignedInterfaceID == interfaceID
        else {
            throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.string(assignment.addressID))
        }
        guard desiredByID[assignment.id] == nil else { return }
        snapshot.assignments.removeValue(forKey: assignment.id)
        try changes.tombstone(assignment, recordType: "IPAddressAssignment")
        address.assignedInterfaceID = nil
        snapshot.addresses[address.id] = address
        try changes.saveStringKeyed(address, resourceKey: .string(address.id), recordType: "IPAddressRecord")
    }

    private func saveAssignment(
        _ assignment: IPAddressAssignment, currentByID: [ObjectID: IPAddressAssignment], interfaceID: ObjectID, snapshot: inout Snapshot,
        changes: inout ChangeAccumulator
    ) throws {
        guard var address = snapshot.addresses[assignment.addressID], address.isActive else {
            throw ProductionMutationPlannerError.missingIPAMObject(.string(assignment.addressID))
        }
        try validateAssignmentPrecondition(assignment, current: currentByID[assignment.id], interfaceID: interfaceID, address: address, snapshot: snapshot)
        snapshot.assignments[assignment.id] = assignment
        if currentByID[assignment.id] != assignment {
            try changes.save(assignment, recordType: "IPAddressAssignment")
        }
        if address.assignedInterfaceID != interfaceID {
            address.assignedInterfaceID = interfaceID
            snapshot.addresses[address.id] = address
            try changes.saveStringKeyed(address, resourceKey: .string(address.id), recordType: "IPAddressRecord")
        }
    }

    private func validateAssignmentPrecondition(
        _ assignment: IPAddressAssignment, current: IPAddressAssignment?, interfaceID: ObjectID, address: IPAddressRecord, snapshot: Snapshot
    ) throws {
        if let current {
            guard current.addressID == assignment.addressID,
                current.interfaceID == assignment.interfaceID,
                address.assignedInterfaceID == interfaceID
            else {
                throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(assignment.id))
            }
        } else if snapshot.assignments[assignment.id] != nil || address.assignedInterfaceID != nil {
            throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.string(assignment.addressID))
        }
    }

    private func applyVLANMemberships(_ memberships: InterfaceVLANMembershipSet, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        let current = try validatedCurrentMemberships(memberships, snapshot: snapshot)
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let desired = sortedMemberships(memberships.desiredMemberships)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        for membership in current where desiredByID[membership.id] == nil {
            snapshot.memberships.removeValue(forKey: membership.id)
            try changes.tombstone(membership, recordType: "InterfaceVLANMembership")
        }
        for membership in desired {
            try saveMembership(membership, currentByID: currentByID, snapshot: &snapshot, changes: &changes)
        }
    }

    private func validatedCurrentMemberships(_ memberships: InterfaceVLANMembershipSet, snapshot: Snapshot) throws -> [InterfaceVLANMembership] {
        guard snapshot.vrfs[memberships.revisionVRF.id] == memberships.revisionVRF,
            let interface = snapshot.interfaces[memberships.interfaceID], interface.isActive
        else {
            throw ProductionMutationPlannerError.missingIPAMObject(.object(memberships.interfaceID))
        }
        let current = sortedMemberships(
            snapshot.memberships.values.filter {
                $0.isActive && $0.interfaceID == memberships.interfaceID
            })
        guard current == sortedMemberships(memberships.currentMemberships) else {
            throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(memberships.interfaceID))
        }
        guard isValid(memberships, for: interface) else {
            throw ProductionMutationPlannerError.invalidIPAMRelationshipSet(.object(memberships.interfaceID))
        }
        return current
    }

    private func saveMembership(
        _ membership: InterfaceVLANMembership, currentByID: [ObjectID: InterfaceVLANMembership], snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        guard snapshot.vlans[membership.vlanID]?.isActive == true else {
            throw ProductionMutationPlannerError.missingIPAMObject(.object(membership.vlanID))
        }
        if let current = currentByID[membership.id] {
            guard current.interfaceID == membership.interfaceID,
                current.vlanID == membership.vlanID
            else {
                throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(membership.id))
            }
        } else if snapshot.memberships[membership.id] != nil {
            throw ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(membership.id))
        }
        snapshot.memberships[membership.id] = membership
        if currentByID[membership.id] != membership {
            try changes.save(membership, recordType: "InterfaceVLANMembership")
        }
    }

    func sortedAssignments<S: Sequence>(_ values: S) -> [IPAddressAssignment] where S.Element == IPAddressAssignment {
        values.sorted { lhs, rhs in lhs.id == rhs.id ? lhs.addressID < rhs.addressID : lhs.id < rhs.id }
    }

    func sortedMemberships<S: Sequence>(_ values: S) -> [InterfaceVLANMembership] where S.Element == InterfaceVLANMembership {
        values.sorted { lhs, rhs in lhs.id == rhs.id ? lhs.vlanID < rhs.vlanID : lhs.id < rhs.id }
    }

    func isValid(_ assignments: InterfaceAddressAssignmentSet) -> Bool {
        let desired = assignments.desiredAssignments
        guard assignments.currentAssignments.allSatisfy({ $0.isActive && $0.interfaceID == assignments.interfaceID }),
            desired.allSatisfy({ $0.isActive && $0.interfaceID == assignments.interfaceID }),
            Set(assignments.currentAssignments.map(\.id)).count == assignments.currentAssignments.count,
            Set(assignments.currentAssignments.map(\.addressID)).count == assignments.currentAssignments.count,
            Set(desired.map(\.id)).count == desired.count,
            Set(desired.map(\.addressID)).count == desired.count
        else {
            return false
        }
        let primaries = desired.filter(\.isPrimary)
        return (desired.isEmpty && assignments.primaryAddressID == nil) || (primaries.count == 1 && primaries.first?.addressID == assignments.primaryAddressID)
    }

    func isValid(_ memberships: InterfaceVLANMembershipSet, for interface: Interface) -> Bool {
        let desired = memberships.desiredMemberships
        guard memberships.currentMemberships.allSatisfy({ $0.isActive && $0.interfaceID == memberships.interfaceID }),
            desired.allSatisfy({ $0.isActive && $0.interfaceID == memberships.interfaceID }),
            Set(memberships.currentMemberships.map(\.id)).count == memberships.currentMemberships.count,
            Set(memberships.currentMemberships.map(\.vlanID)).count == memberships.currentMemberships.count,
            Set(desired.map(\.id)).count == desired.count,
            Set(desired.map(\.vlanID)).count == desired.count
        else {
            return false
        }
        switch interface.mode {
        case .access:
            return desired.count == 1 && desired[0].isNative
        case .trunk:
            return !desired.isEmpty && desired.filter(\.isNative).count <= 1
        case .routed:
            return desired.isEmpty
        }
    }
}
