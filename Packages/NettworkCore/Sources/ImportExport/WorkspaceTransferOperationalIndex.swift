import Foundation
import NetworkModel
import WorkspaceChangeControl

extension WorkspaceTransferCandidateValidator {
    static func validateReservationLocks(
        _ locks: [ResourceReservationLock],
        workOrders: [ObjectID: WorkOrder], terminal: Bool
    ) throws {
        for lock in locks {
            guard let workOrder = workOrders[lock.workOrderID],
                let reservation = workOrder.reservation,
                let intentDigest = workOrder.intentDigest,
                reservation.id == lock.reservationID,
                reservation.ownerID == lock.ownerID,
                reservation.resourceKeys.contains(lock.resourceKey),
                intentDigest == lock.intentDigest
            else {
                throw WorkspaceTransferValidationError.missingReference(kind: "work-order reservation lock", id: lock.id.description)
            }
            try validateAcknowledgement(reservation, workOrder: workOrder, lock: lock, intentDigest: intentDigest)
            try validateCanonicalIntent(workOrder, reservation: reservation, lock: lock)
            guard terminal == isTerminal(workOrder.status) else {
                throw WorkspaceTransferValidationError.operationalValidationFailed
            }
        }
    }

    private static func validateAcknowledgement(
        _ reservation: WorkOrderReservation, workOrder: WorkOrder,
        lock: ResourceReservationLock, intentDigest: IntentDigest
    ) throws {
        guard let acknowledgement = reservation.acknowledgedByCloudKit else { return }
        guard acknowledgement.reservationID == reservation.id, acknowledgement.workOrderID == workOrder.id,
            acknowledgement.ownerID == reservation.ownerID,
            acknowledgement.cloudKitAccountRecordName == acknowledgement.ownerID,
            acknowledgement.resourceKeys == reservation.resourceKeys,
            acknowledgement.intentDigest == intentDigest, acknowledgement.expiresAt == lock.expiresAt
        else {
            throw WorkspaceTransferValidationError.missingReference(kind: "work-order reservation lock", id: lock.id.description)
        }
    }

    private static func validateCanonicalIntent(
        _ workOrder: WorkOrder, reservation: WorkOrderReservation,
        lock: ResourceReservationLock
    ) throws {
        let canonical = CanonicalWorkIntent(
            intentSchemaVersion: workOrder.intentSchemaVersion ?? 1, workOrderID: workOrder.id, kind: workOrder.kind, creatorID: workOrder.creatorID,
            ticket: workOrder.ticket,
            notes: workOrder.notes, operations: workOrder.plannedOperations, resourceKeys: reservation.resourceKeys, evidenceHashes: workOrder.evidenceHashes)
        guard (try? canonical.digest()) == lock.intentDigest else {
            throw WorkspaceTransferValidationError.operationalValidationFailed
        }
    }

    private static func isTerminal(_ status: WorkOrderStatus) -> Bool {
        switch status {
        case .completed, .cancelled, .reconciliation: true
        default: false
        }
    }

    static func unique<T, ID: Hashable>(_ values: [T], id: (T) -> ID) throws -> [ID: T] {
        var result: [ID: T] = [:]
        for value in values {
            guard result.updateValue(value, forKey: id(value)) == nil else {
                throw WorkspaceTransferValidationError.operationalValidationFailed
            }
        }
        return result
    }
}

struct OperationalIndex {
    let workOrders: [ObjectID: WorkOrder]
    let liveLocks: [ResourceKey: ResourceReservationLock]
    let releasedLocks: [ResourceKey: ResourceReservationLock]
    let receipts: [ObjectID: OperationReceipt]
    let quotaLedgers: [ObjectID: AttachmentEvidenceQuotaLedger]
    let releases: [ObjectID: AttachmentEvidenceReservationRelease]
    let bindingsByAttachment: [ObjectID: AttachmentEvidenceBindingRecord]
    let bindingsByReservation: [ObjectID: AttachmentEvidenceBindingRecord]
    let bindingsByWorkOrder: [ObjectID: [AttachmentEvidenceBindingRecord]]

    init(
        workOrders: [WorkOrder], reservationLocks: [ResourceReservationLock],
        releasedReservationLocks: [ResourceReservationLock], receipts: [OperationReceipt],
        quotaLedgers: [AttachmentEvidenceQuotaLedger],
        reservationReleases: [AttachmentEvidenceReservationRelease],
        bindings: [AttachmentEvidenceBindingRecord], floorPlanBindings: [FloorPlanAssetBindingRecord]
    ) throws {
        self.workOrders = try WorkspaceTransferCandidateValidator.unique(workOrders, id: \.id)
        self.liveLocks = try WorkspaceTransferCandidateValidator.unique(reservationLocks, id: \.id)
        self.releasedLocks = try WorkspaceTransferCandidateValidator.unique(releasedReservationLocks, id: \.id)
        self.receipts = try WorkspaceTransferCandidateValidator.unique(receipts, id: \.operationID)
        self.quotaLedgers = try WorkspaceTransferCandidateValidator.unique(quotaLedgers, id: \.workOrderID)
        self.releases = try WorkspaceTransferCandidateValidator.unique(reservationReleases, id: \.id)
        self.bindingsByAttachment = try WorkspaceTransferCandidateValidator.unique(bindings, id: \.attachmentID)
        self.bindingsByReservation = try WorkspaceTransferCandidateValidator.unique(bindings, id: \.reservationID)
        self.bindingsByWorkOrder = Dictionary(grouping: bindings, by: \.workOrderID)
        _ = try WorkspaceTransferCandidateValidator.unique(floorPlanBindings, id: \.floorID)
    }
}
