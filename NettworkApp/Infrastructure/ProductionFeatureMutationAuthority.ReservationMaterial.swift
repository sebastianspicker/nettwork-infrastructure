import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    struct ReservationMaterial {
        let workOrder: WorkOrder
        let digest: IntentDigest
        let reservationID: ObjectID
        let operationID: ObjectID
        let expiresAt: Date
        let lockSaves: [AuthoritativeRecordSave]
    }

    func reservationMaterial(for draft: WorkOrderDraft, trusted: TrustedProductionSession) throws -> ReservationMaterial {
        let intent = canonicalIntent(for: draft, creatorID: trusted.actor.cloudKitUserRecordName)
        let digest = try intent.digest()
        let operationID = stableID(domain: "reserve-work-order", components: [draft.id.description, digest.hexadecimalString])
        let reservationID = WorkOrderReservation.deterministicID(for: operationID)
        let expiresAt = trusted.actorSnapshot.capturedAt.addingTimeInterval(policy.reservationLifetime)
        let reservation = WorkOrderReservation(id: reservationID, ownerID: trusted.actor.cloudKitUserRecordName, resourceKeys: draft.resourceKeys)
        let reserved = WorkOrder(
            id: draft.id,
            kind: draft.kind,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .reserved,
            creatorID: trusted.actor.cloudKitUserRecordName,
            ticket: normalized(draft.ticket),
            notes: normalized(draft.notes),
            plannedOperations: draft.operations,
            revision: 0,
            intentDigest: digest,
            reservation: reservation,
            evidenceHashes: draft.evidence
        )
        let lockSaves = try ResourceReservationLockFactory.saves(for: reserved, expiresAt: expiresAt, observedAt: trusted.actorSnapshot.capturedAt)
        guard lockSaves.count + 4 <= AtomicCloudMutation.maximumBusinessRecordsPerOperation else {
            throw ProductionFeatureMutationAuthorityError.invalidDraft([
                "Split this change into smaller work orders before reservation; it exceeds the atomic record limit."
            ])
        }
        return ReservationMaterial(
            workOrder: reserved, digest: digest, reservationID: reservationID, operationID: operationID, expiresAt: expiresAt, lockSaves: lockSaves
        )
    }

    func commitReservation(_ material: ReservationMaterial, trusted: TrustedProductionSession, namespace: PersistenceNamespace) async throws {
        let workspaceAssertion = try await activeWorkspaceAssertion(in: namespace)
        let mutation = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: material.operationID,
            workspaceZone: namespace.workspaceZone,
            actor: trusted.actorSnapshot,
            currentWorkOrder: nil,
            updatedWorkOrder: material.workOrder,
            state: AuthoritativeMutationState(knownRecords: [workspaceAssertion.resourceKey: workspaceAssertion.precondition]),
            saves: material.lockSaves,
            readAssertions: [workspaceAssertion],
            policyVersion: policy.policyVersion
        )
        try await sessionAuthorizer.revalidate(trusted)
        let receipt = try await mutations.commit(mutation)
        guard receipt == mutation.receipt else { throw ProductionFeatureMutationAuthorityError.receiptMismatch }
    }

    func acknowledgeReservation(
        _ material: ReservationMaterial, authorization: OperationsAuthorization, namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        let refreshed = try await sessionAuthorizer.authorizeMutation(namespace: namespace, presentation: authorization)
        let operationID = stableID(domain: "acknowledge-reservation", components: [material.reservationID.description, material.digest.hexadecimalString])
        let acknowledged = try await acknowledgements.acknowledge(
            reservedWorkOrder: material.workOrder, account: refreshed.account, actor: refreshed.actor,
            actorSnapshot: refreshed.actorSnapshot, operationID: operationID, expiresAt: material.expiresAt, policyVersion: policy.policyVersion
        )
        guard acknowledged.workOrder.reservation?.id == material.reservationID,
            acknowledged.receipt.operationID == operationID
        else {
            throw ProductionFeatureMutationAuthorityError.receiptMismatch
        }
        return presentation(for: acknowledged.workOrder, confirmation: .confirmed)
    }
}
