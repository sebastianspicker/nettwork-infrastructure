import CloudSync
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    func canonicalIntent(for draft: WorkOrderDraft, creatorID: String) -> CanonicalWorkIntent {
        CanonicalWorkIntent(
            workOrderID: draft.id,
            kind: draft.kind,
            creatorID: creatorID,
            ticket: normalized(draft.ticket),
            notes: normalized(draft.notes),
            operations: draft.operations,
            resourceKeys: draft.resourceKeys,
            evidenceHashes: draft.evidence
        )
    }

    func structuralIssues(for draft: WorkOrderDraft) -> [String] {
        var issues: [String] = []
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("A title is required.") }
        if normalized(draft.ticket) == nil { issues.append("A ticket or change reference is required.") }
        if draft.operations.isEmpty { issues.append("At least one typed planned operation is required.") }
        if draft.resourceKeys.isEmpty { issues.append("The exact resource set is required.") }
        if draft.operations.contains(where: { operation in
            if case .topology(.remove(_)) = operation { return true }
            return false
        }) {
            issues.append("Device removal requires a typed decommission snapshot.")
        }
        if !draft.resourceKeys.isEmpty, !draft.operations.isEmpty,
            !operationResourceKeys(draft.operations).isSubset(of: draft.resourceKeys)
        {
            issues.append("The declared resource set does not cover every typed operation.")
        }
        let conservativeRecordCount = draft.resourceKeys.count + draft.evidence.count + 4
        if conservativeRecordCount > AtomicCloudMutation.maximumBusinessRecordsPerOperation {
            issues.append("Split this change into smaller work orders before reservation; it exceeds the atomic record limit.")
        }
        return issues
    }

    func requireStructurallyValid(_ draft: WorkOrderDraft) throws {
        let issues = structuralIssues(for: draft)
        guard issues.isEmpty else { throw ProductionFeatureMutationAuthorityError.invalidDraft(issues) }
    }

    private func operationResourceKeys(_ operations: [PlannedWorkOperation]) -> Set<ResourceKey> {
        var keys = Set<ResourceKey>()
        for operation in operations {
            keys.formUnion(operation.productionResourceKeys)
        }
        return keys
    }

    func isWellFormed(_ assignments: InterfaceAddressAssignmentSet) -> Bool {
        let current = assignments.currentAssignments
        let desired = assignments.desiredAssignments
        guard assignments.revisionVRF.isActive,
            current.allSatisfy({ $0.isActive && $0.interfaceID == assignments.interfaceID }),
            desired.allSatisfy({ $0.isActive && $0.interfaceID == assignments.interfaceID }),
            Set(current.map(\.id)).count == current.count,
            Set(current.map(\.addressID)).count == current.count,
            Set(desired.map(\.id)).count == desired.count,
            Set(desired.map(\.addressID)).count == desired.count
        else {
            return false
        }
        let primaryMatches = desired.filter { $0.addressID == assignments.primaryAddressID && $0.isPrimary }
        return (desired.isEmpty && assignments.primaryAddressID == nil)
            || (assignments.primaryAddressID != nil && primaryMatches.count == 1 && desired.filter(\.isPrimary).count == 1)
    }

    func isWellFormed(_ memberships: InterfaceVLANMembershipSet) -> Bool {
        let current = memberships.currentMemberships
        let desired = memberships.desiredMemberships
        return memberships.revisionVRF.isActive && current.allSatisfy({ $0.isActive && $0.interfaceID == memberships.interfaceID })
            && desired.allSatisfy({ $0.isActive && $0.interfaceID == memberships.interfaceID }) && Set(current.map(\.id)).count == current.count
            && Set(current.map(\.vlanID)).count == current.count && Set(desired.map(\.id)).count == desired.count
            && Set(desired.map(\.vlanID)).count == desired.count
    }

    func resourceKeys(for assignments: InterfaceAddressAssignmentSet) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(assignments.revisionVRF.id), .object(assignments.interfaceID)]
        for assignment in assignments.currentAssignments + assignments.desiredAssignments {
            keys.formUnion([.object(assignment.id), .string(assignment.addressID), .object(assignment.interfaceID)])
        }
        return keys
    }

    func resourceKeys(for memberships: InterfaceVLANMembershipSet) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(memberships.revisionVRF.id), .object(memberships.interfaceID)]
        for membership in memberships.currentMemberships + memberships.desiredMemberships {
            keys.formUnion([.object(membership.id), .object(membership.interfaceID), .object(membership.vlanID)])
        }
        return keys
    }

    func presentation(for workOrder: WorkOrder, confirmation: WorkOrderReservationPresentation.Confirmation) -> WorkOrderReservationPresentation {
        guard let reservation = workOrder.reservation, let exactIntentDigest = workOrder.intentDigest else {
            preconditionFailure("Reservation presentation requires a reserved work order with an intent digest.")
        }
        return WorkOrderReservationPresentation(
            id: reservation.id, workOrderID: workOrder.id, exactIntentDigest: exactIntentDigest,
            resourceKeys: reservation.resourceKeys, expiresAt: reservation.acknowledgedByCloudKit?.expiresAt ?? .distantPast,
            confirmation: confirmation, workOrderStatus: workOrder.status, cancellationRequestID: workOrder.cancellationHistory.last?.id
        )
    }

    func normalized(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    func digestString(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func stableID(domain: String, components: [String]) -> ObjectID {
        var material = Data("nettwork.app.\(domain).v1".utf8)
        for component in components {
            material.append(0)
            material.append(Data(component.utf8))
        }
        let hex = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        guard
            let uuid = UUID(
                uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-"
                    + "\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
            )
        else {
            preconditionFailure("A SHA-256 digest must produce a valid UUID representation.")
        }
        return ObjectID(uuid)
    }
}
