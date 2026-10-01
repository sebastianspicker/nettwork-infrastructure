import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func stagedEnvelopes(
        transfer: ValidatedWorkspaceTransfer, audits: [AuditEvent], assets: [CloudRecordEnvelope],
        provenance: ArchiveSourceProvenance? = nil, recordedAt: Date? = nil, namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> [CloudRecordEnvelope] {
        let visibility = WorkspaceRecordVisibility.staged(transferID: transferID)
        let restoration = try restoredWorkOrderContext(transfer.candidate.workOrders, target: namespace)
        let records =
            try stagedTransferRecords(
                transfer,
                restoration: restoration,
                namespace: namespace,
                visibility: visibility
            )
            + stagedTransferTombstones(
                transfer.tombstones,
                namespace: namespace,
                visibility: visibility
            )
            + reconciledReservationTombstones(
                transfer.saves, reservationIDs: restoration.reconciledReservationIDs, namespace: namespace, visibility: visibility
            ) + (try stagedAuditEnvelopes(audits, namespace: namespace, visibility: visibility))
        let historicalReferences = try importedHistoricalReferenceEnvelopes(
            transfer: transfer, audits: audits, assets: assets, provenance: provenance, recordedAt: recordedAt, namespace: namespace, transferID: transferID
        )
        return try sortedEnvelopes(records + assets + historicalReferences)
    }

    private func restoredWorkOrderContext(
        _ workOrders: [WorkOrder],
        target: PersistenceNamespace
    ) throws -> (
        restoredWorkOrders: [ObjectID: (original: WorkOrder, restored: WorkOrder)],
        reconciledReservationIDs: Set<ObjectID>
    ) {
        let restoredWorkOrders = try restoredWorkOrders(workOrders, target: target)
        let reconciledReservationIDs = Set(
            restoredWorkOrders.values.compactMap { entry in
                entry.original.status == entry.restored.status ? nil : entry.original.reservation?.id
            })
        return (restoredWorkOrders, reconciledReservationIDs)
    }

    private func stagedTransferRecords(
        _ transfer: ValidatedWorkspaceTransfer,
        restoration: (
            restoredWorkOrders: [ObjectID: (original: WorkOrder, restored: WorkOrder)],
            reconciledReservationIDs: Set<ObjectID>
        ),
        namespace: PersistenceNamespace,
        visibility: WorkspaceRecordVisibility
    ) throws -> [CloudRecordEnvelope] {
        // Evidence bindings carry their protected bytes in their own envelope;
        // staging a second payload-only envelope would lose that relationship.
        try transfer.saves.compactMap { save in
            guard save.recordType != WorkspaceTransferRecordType.attachmentEvidenceBinding.rawValue,
                save.recordType != WorkspaceTransferRecordType.floorPlanAssetBinding.rawValue,
                !isReconciledReservationLock(save, reservationIDs: restoration.reconciledReservationIDs)
            else {
                return nil
            }
            return CloudRecordEnvelope(
                resourceKey: save.resourceKey,
                workspaceID: namespace.workspaceID,
                recordType: save.recordType,
                schemaVersion: save.schemaVersion,
                payload: try restoredPayload(for: save, target: namespace, restoredWorkOrders: restoration.restoredWorkOrders),
                visibility: visibility,
                systemFields: Data(),
                changeTag: ""
            )
        }
    }

    private func stagedTransferTombstones(
        _ tombstones: [AuthoritativeTombstone], namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility
    ) -> [CloudRecordEnvelope] {
        tombstones.map { tombstone in
            CloudRecordEnvelope(
                resourceKey: tombstone.resourceKey,
                workspaceID: namespace.workspaceID,
                recordType: tombstone.recordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                payload: tombstone.encodedTombstone,
                visibility: visibility,
                systemFields: Data(),
                changeTag: "",
                isDeleted: true
            )
        }
    }

    private func reconciledReservationTombstones(
        _ saves: [AuthoritativeRecordSave], reservationIDs: Set<ObjectID>, namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility
    ) -> [CloudRecordEnvelope] {
        saves.compactMap { save in
            guard isReconciledReservationLock(save, reservationIDs: reservationIDs) else {
                return nil
            }
            return CloudRecordEnvelope(
                resourceKey: save.resourceKey,
                workspaceID: namespace.workspaceID,
                recordType: save.recordType,
                schemaVersion: save.schemaVersion,
                payload: save.encodedRecord,
                visibility: visibility,
                systemFields: Data(),
                changeTag: "",
                isDeleted: true
            )
        }
    }

    func stagedAuditEnvelopes(
        _ audits: [AuditEvent], namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility
    ) throws -> [CloudRecordEnvelope] {
        try audits.map { audit in
            CloudRecordEnvelope(
                resourceKey: .object(audit.id),
                workspaceID: namespace.workspaceID,
                recordType: CloudRecordNaming.auditRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                payload: try CloudDeterministicCoding.encode(audit),
                visibility: visibility,
                systemFields: Data(),
                changeTag: ""
            )
        }
    }

    func restoredPayload(
        for save: AuthoritativeRecordSave,
        target: PersistenceNamespace,
        restoredWorkOrders: [ObjectID: (original: WorkOrder, restored: WorkOrder)]
    ) throws -> Data {
        if save.recordType == WorkspaceTransferRecordType.workOrder.rawValue {
            let original = try CloudDeterministicCoding.decode(WorkOrder.self, from: save.encodedRecord)
            return try CloudDeterministicCoding.encode(restoredWorkOrders[original.id]?.restored ?? original)
        }
        guard save.recordType == WorkspaceTransferRecordType.operationReceipt.rawValue else { return save.encodedRecord }
        let receipt = try CloudDeterministicCoding.decode(OperationReceipt.self, from: save.encodedRecord)
        guard receipt.id == save.resourceKey else {
            throw ProductionWorkspaceTransferAuthorityError.malformedArchiveOperationalState
        }
        return try CloudDeterministicCoding.encode(
            OperationReceipt(
                workspaceZone: target.workspaceZone,
                operationID: receipt.operationID,
                intentDigest: receipt.intentDigest,
                auditEventID: receipt.auditEventID
            ))
    }

    func restoredWorkOrders(_ workOrders: [WorkOrder], target: PersistenceNamespace) throws -> [ObjectID: (original: WorkOrder, restored: WorkOrder)] {
        var result: [ObjectID: (original: WorkOrder, restored: WorkOrder)] = [:]
        for original in workOrders {
            guard let reservation = original.reservation else {
                result[original.id] = (original, original)
                continue
            }
            let requiresReconciliation = [
                WorkOrderStatus.reserved, .approved, .executing, .cancellationRequested,
            ].contains(original.status)
            let clearsNonportableAcknowledgement =
                reservation.acknowledgedByCloudKit.map {
                    $0.workspaceZone != target.workspaceZone
                } ?? false
            guard requiresReconciliation || clearsNonportableAcknowledgement else {
                result[original.id] = (original, original)
                continue
            }
            guard original.revision < Int.max else {
                throw ProductionWorkspaceTransferAuthorityError.malformedArchiveOperationalState
            }
            var restored = WorkOrder(
                id: original.id,
                kind: original.kind,
                title: original.title,
                status: requiresReconciliation ? .reconciliation : original.status,
                reservedResourceIDs: original.reservedResourceIDs,
                creatorID: original.creatorID,
                ticket: original.ticket,
                notes: original.notes,
                plannedOperations: original.plannedOperations,
                revision: original.revision + 1,
                intentDigest: original.intentDigest,
                intentSchemaVersion: original.intentSchemaVersion,
                reservation: WorkOrderReservation(
                    id: reservation.id, ownerID: reservation.ownerID, resourceKeys: reservation.resourceKeys, acknowledgedByCloudKit: nil
                ),
                approvedBy: original.approvedBy,
                approvedAt: original.approvedAt,
                executedBy: original.executedBy,
                executionStartedAt: original.executionStartedAt,
                completedAt: original.completedAt,
                evidenceHashes: original.evidenceHashes,
                cancellationHistory: original.cancellationHistory
            )
            restored.cancellationReason = original.cancellationReason
            result[original.id] = (original, restored)
        }
        return result
    }

    func isReconciledReservationLock(_ save: AuthoritativeRecordSave, reservationIDs: Set<ObjectID>) -> Bool {
        guard save.recordType == WorkspaceTransferRecordType.reservationLock.rawValue,
            let lock = try? CloudDeterministicCoding.decode(ResourceReservationLock.self, from: save.encodedRecord)
        else { return false }
        return reservationIDs.contains(lock.reservationID)
    }
}
