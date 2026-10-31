import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    /// Continues a reservation whose phase one already committed. The work
    /// order and its locks are durable on the server, so a retry must neither
    /// write the locks again nor choose a new expiry for them: it adopts the
    /// expiry the locks carry and finishes or re-reads the acknowledgement.
    /// Returns nil when no reservation of this exact draft exists yet.
    func resumedReservation(
        _ material: ReservationMaterial, authorization: OperationsAuthorization, namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation? {
        let existing: WorkOrder
        do {
            (existing, _) = try await exactWorkOrder(id: material.workOrder.id, in: namespace)
        } catch ProductionFeatureMutationAuthorityError.workOrderMissing {
            return nil
        }
        guard existing.status == .reserved,
            existing.reservation?.id == material.reservationID,
            existing.intentDigest == material.digest
        else {
            return nil
        }
        if existing.reservation?.acknowledgedByCloudKit != nil {
            return try await refreshReservation(presentation(for: existing, confirmation: .pending), authorization: authorization, in: namespace)
        }
        let expiresAt = try await persistedLockExpiry(for: existing, namespace: namespace)
        // Phase one is not repeated, so the original lock saves are not needed.
        let resumed = ReservationMaterial(
            workOrder: material.workOrder, digest: material.digest, reservationID: material.reservationID,
            operationID: material.operationID, expiresAt: expiresAt, lockSaves: []
        )
        return try await acknowledgeReservation(resumed, authorization: authorization, namespace: namespace)
    }

    /// The single expiry shared by every lock of `workOrder`; any missing,
    /// foreign or disagreeing lock fails closed.
    private func persistedLockExpiry(for workOrder: WorkOrder, namespace: PersistenceNamespace) async throws -> Date {
        guard let reservation = workOrder.reservation, !reservation.resourceKeys.isEmpty else {
            throw ProductionFeatureMutationAuthorityError.invalidReservation
        }
        var expiries: Set<Date> = []
        for resourceKey in reservation.resourceKeys {
            let lockKey = ResourceKey.reservationLock(for: resourceKey)
            guard let snapshot = try await exactRecords.exactRecord(for: lockKey, in: namespace.workspaceZone),
                snapshot.workspaceZone == namespace.workspaceZone,
                snapshot.resourceKey == lockKey,
                let lock = try? CloudDeterministicCoding.decode(ResourceReservationLock.self, from: snapshot.payload),
                lock.resourceKey == resourceKey,
                lock.workOrderID == workOrder.id,
                lock.reservationID == reservation.id,
                lock.ownerID == reservation.ownerID,
                lock.intentDigest == workOrder.intentDigest
            else {
                throw ProductionFeatureMutationAuthorityError.invalidReservation
            }
            expiries.insert(lock.expiresAt)
        }
        guard expiries.count == 1, let expiresAt = expiries.first else {
            throw ProductionFeatureMutationAuthorityError.invalidReservation
        }
        return expiresAt
    }
}
