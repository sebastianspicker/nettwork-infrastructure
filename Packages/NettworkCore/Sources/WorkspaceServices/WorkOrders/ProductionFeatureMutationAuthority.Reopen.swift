import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    public func stagedDrafts(in namespace: PersistenceNamespace) async throws -> [WorkOrderDraft] {
        guard namespace == account.namespace else {
            throw ProductionFeatureMutationAuthorityError.namespaceMismatch
        }
        return try await draftStore.drafts(in: namespace)
    }

    /// Reads one work order from the authoritative records, not the mirror, so
    /// it can be continued after a relaunch. Reading grants nothing: every
    /// later lifecycle action re-runs its own authorization and validation
    /// against the then-current record.
    public func reopenWorkOrder(
        id: ObjectID, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ReopenedWorkOrder {
        let trusted = try await authorize(authorization, namespace: namespace)
        let (workOrder, _) = try await exactWorkOrder(id: id, in: namespace)
        try await sessionAuthorizer.revalidate(trusted)
        let resourceKeys = workOrder.reservation?.resourceKeys ?? Set(workOrder.reservedResourceIDs.map { ResourceKey.object($0) })
        let draft = WorkOrderDraft(
            id: workOrder.id, title: workOrder.title, kind: workOrder.kind, ticket: workOrder.ticket ?? "", notes: workOrder.notes ?? "",
            resourceKeys: resourceKeys, operations: workOrder.plannedOperations, evidence: workOrder.evidenceHashes)
        guard workOrder.reservation != nil, workOrder.intentDigest != nil else {
            return ReopenedWorkOrder(draft: draft, status: workOrder.status, reservation: nil)
        }
        let reservation = presentation(for: workOrder, confirmation: reservationConfirmation(of: workOrder))
        return ReopenedWorkOrder(draft: draft, status: workOrder.status, reservation: reservation)
    }

    /// Confirmed only while the server acknowledgement is unexpired; a
    /// reservation the server never acknowledged stays pending.
    func reservationConfirmation(of workOrder: WorkOrder) -> WorkOrderReservationPresentation.Confirmation {
        guard let acknowledgement = workOrder.reservation?.acknowledgedByCloudKit else { return .pending }
        return Date.now < acknowledgement.expiresAt ? .confirmed : .expired
    }
}
