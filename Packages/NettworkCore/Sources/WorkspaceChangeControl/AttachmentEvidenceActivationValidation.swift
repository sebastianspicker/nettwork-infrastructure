import Foundation
import NetworkModel

extension AuthoritativeActivationMutationValidator {
    static func validateAttachmentEvidenceActivation(
        _ mutation: AuthoritativeActivationMutation,
        state: AuthoritativeActivationMutationState, sentinelSave: AuthoritativeRecordSave,
        bindingSave: AuthoritativeRecordSave
    ) throws -> ObjectID {
        let businessSaves = mutation.saves.filter { $0.resourceKey != sentinelSave.resourceKey }
        try validateAttachmentEvidenceRecordSet(mutation, businessSaves: businessSaves, bindingSave: bindingSave)
        let inputs = try attachmentEvidenceInputs(
            mutation, businessSaves: businessSaves,
            bindingSave: bindingSave)
        try validateAttachmentEvidenceLedger(inputs, state: state, mutation: mutation)
        return inputs.binding.workOrderID
    }

    static func validateAttachmentEvidenceRecordSet(
        _ mutation: AuthoritativeActivationMutation,
        businessSaves: [AuthoritativeRecordSave], bindingSave: AuthoritativeRecordSave
    ) throws {
        guard businessSaves.count == 3,
            Set(businessSaves.map(\.recordType)) == AuthoritativeActivationMutation.attachmentEvidenceActivationRecordTypes,
            mutation.readAssertions.count == 1
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(bindingSave.resourceKey)
        }
    }

    static func attachmentEvidenceInputs(
        _ mutation: AuthoritativeActivationMutation,
        businessSaves: [AuthoritativeRecordSave], bindingSave: AuthoritativeRecordSave
    ) throws -> AttachmentEvidenceActivationInputs {
        let workOrder = try attachmentWorkOrder(mutation, bindingSave: bindingSave)
        let binding = try attachmentBinding(mutation, bindingSave: bindingSave, workOrder: workOrder)
        let release = try attachmentRelease(mutation, businessSaves: businessSaves, binding: binding)
        let ledger = try attachmentLedger(mutation, businessSaves: businessSaves, binding: binding)
        return AttachmentEvidenceActivationInputs(binding: binding, release: release, ledger: ledger)
    }

    static func attachmentWorkOrder(
        _ mutation: AuthoritativeActivationMutation,
        bindingSave: AuthoritativeRecordSave
    ) throws -> WorkOrder {
        guard let assertion = mutation.readAssertions.first, assertion.recordType == WorkspaceRecordType.workOrder,
            assertion.schemaVersion == 1,
            let workOrder = try? CanonicalJSONCoding.decode(WorkOrder.self, from: assertion.encodedRecord),
            let reencoded = try? CanonicalJSONCoding.encode(workOrder),
            CanonicalPayloadComparison.matches(stored: assertion.encodedRecord, reencoded: reencoded),
            assertion.resourceKey == .object(workOrder.id), let intentDigest = workOrder.intentDigest,
            [.reserved, .approved, .executing].contains(workOrder.status),
            let reservation = workOrder.reservation, reservation.ownerID == mutation.actor.actorID,
            isValidAttachmentIntent(workOrder, reservation: reservation, intentDigest: intentDigest),
            isValidAttachmentAcknowledgement(
                reservation, intentDigest: intentDigest, mutation: mutation,
                workOrderID: workOrder.id)
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(bindingSave.resourceKey)
        }
        return workOrder
    }

    static func isValidAttachmentIntent(
        _ workOrder: WorkOrder, reservation: WorkOrderReservation,
        intentDigest: IntentDigest
    ) -> Bool {
        (try? CanonicalWorkIntent(
            intentSchemaVersion: workOrder.intentSchemaVersion ?? 1,
            workOrderID: workOrder.id, kind: workOrder.kind, creatorID: workOrder.creatorID,
            ticket: workOrder.ticket, notes: workOrder.notes, operations: workOrder.plannedOperations,
            resourceKeys: reservation.resourceKeys, evidenceHashes: workOrder.evidenceHashes
        ).digest()) == intentDigest
    }

    static func isValidAttachmentAcknowledgement(
        _ reservation: WorkOrderReservation,
        intentDigest: IntentDigest, mutation: AuthoritativeActivationMutation, workOrderID: ObjectID
    ) -> Bool {
        guard let acknowledgement = reservation.acknowledgedByCloudKit else { return false }
        return hasMatchingAcknowledgementIdentity(
            acknowledgement, reservation: reservation,
            intentDigest: intentDigest, mutation: mutation, workOrderID: workOrderID
        ) && hasValidAcknowledgementTiming(acknowledgement, capturedAt: mutation.actor.capturedAt)
    }

    static func hasMatchingAcknowledgementIdentity(
        _ acknowledgement: CloudKitAcknowledgement,
        reservation: WorkOrderReservation, intentDigest: IntentDigest,
        mutation: AuthoritativeActivationMutation, workOrderID: ObjectID
    ) -> Bool {
        acknowledgement.workspaceZone == mutation.workspaceZone && acknowledgement.cloudKitAccountRecordName == mutation.actor.actorID
            && acknowledgement.sessionGeneration == mutation.actor.sessionGeneration && acknowledgement.reservationID == reservation.id
            && acknowledgement.workOrderID == workOrderID && acknowledgement.ownerID == reservation.ownerID
            && acknowledgement.resourceKeys == reservation.resourceKeys && acknowledgement.intentDigest == intentDigest
    }

    static func hasValidAcknowledgementTiming(
        _ acknowledgement: CloudKitAcknowledgement, capturedAt: Date
    ) -> Bool {
        !acknowledgement.systemFields.isEmpty && !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acknowledgement.acknowledgedAt <= capturedAt && capturedAt < acknowledgement.expiresAt
    }

    static func attachmentBinding(
        _ mutation: AuthoritativeActivationMutation,
        bindingSave: AuthoritativeRecordSave, workOrder: WorkOrder
    ) throws -> AttachmentEvidenceBindingRecord {
        guard let binding = try? CanonicalJSONCoding.decode(AttachmentEvidenceBindingRecord.self, from: bindingSave.encodedRecord),
            (try? CanonicalJSONCoding.encode(binding)) == bindingSave.encodedRecord,
            binding.resourceKey == bindingSave.resourceKey, binding.workOrderID == workOrder.id,
            binding.intentDigest == mutation.intentDigest, binding.operationID == mutation.operationID,
            binding.auditEventID == mutation.auditEvent.id, binding.boundAt == mutation.actor.capturedAt,
            workOrder.evidenceHashes.contains(binding.evidence)
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(bindingSave.resourceKey)
        }
        return binding
    }

    static func attachmentRelease(
        _ mutation: AuthoritativeActivationMutation,
        businessSaves: [AuthoritativeRecordSave], binding: AttachmentEvidenceBindingRecord
    ) throws -> AttachmentEvidenceReservationRelease {
        guard
            let releaseSave = businessSaves.first(where: {
                $0.recordType == WorkspaceRecordType.attachmentEvidenceReservationRelease
            }),
            let release = try? CanonicalJSONCoding.decode(AttachmentEvidenceReservationRelease.self, from: releaseSave.encodedRecord),
            (try? CanonicalJSONCoding.encode(release)) == releaseSave.encodedRecord,
            release.resourceKey == releaseSave.resourceKey, release.id == binding.reservationID,
            release.workOrderID == binding.workOrderID, release.attachmentID == binding.attachmentID,
            release.reservedCount == 1, release.reservedBytes == binding.provenance.byteCount,
            release.operationID == mutation.operationID, release.releasedAt == mutation.actor.capturedAt
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(binding.resourceKey)
        }
        return release
    }

    static func attachmentLedger(
        _ mutation: AuthoritativeActivationMutation,
        businessSaves: [AuthoritativeRecordSave], binding: AttachmentEvidenceBindingRecord
    ) throws -> AttachmentEvidenceQuotaLedger {
        guard
            let ledgerSave = businessSaves.first(where: {
                $0.recordType == WorkspaceRecordType.attachmentEvidenceQuotaLedger
            }),
            let ledger = try? CanonicalJSONCoding.decode(AttachmentEvidenceQuotaLedger.self, from: ledgerSave.encodedRecord),
            (try? CanonicalJSONCoding.encode(ledger)) == ledgerSave.encodedRecord,
            ledger.resourceKey == ledgerSave.resourceKey, ledger.workOrderID == binding.workOrderID,
            ledger.updatedAt == mutation.actor.capturedAt
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(binding.resourceKey)
        }
        return ledger
    }

    static func validateAttachmentEvidenceLedger(
        _ inputs: AttachmentEvidenceActivationInputs,
        state: AuthoritativeActivationMutationState, mutation: AuthoritativeActivationMutation
    ) throws {
        let expectedLedger = try expectedAttachmentLedger(inputs, state: state, mutation: mutation)
        guard inputs.ledger == expectedLedger else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(inputs.ledger.resourceKey)
        }
    }

    static func expectedAttachmentLedger(
        _ inputs: AttachmentEvidenceActivationInputs,
        state: AuthoritativeActivationMutationState, mutation: AuthoritativeActivationMutation
    ) throws -> AttachmentEvidenceQuotaLedger? {
        if let priorLedger = state.currentRecords[inputs.ledger.resourceKey] {
            let decoded = try decodePriorAttachmentLedger(priorLedger, key: inputs.ledger.resourceKey)
            return try? decoded.consuming(byteCount: inputs.release.reservedBytes, at: mutation.actor.capturedAt)
        }
        return try? AttachmentEvidenceQuotaLedger(
            workOrderID: inputs.binding.workOrderID,
            updatedAt: mutation.actor.capturedAt
        ).consuming(byteCount: inputs.release.reservedBytes, at: mutation.actor.capturedAt)
    }

    static func decodePriorAttachmentLedger(
        _ priorLedger: AuthoritativeActivationRecordSnapshot,
        key: ResourceKey
    ) throws -> AttachmentEvidenceQuotaLedger {
        guard priorLedger.recordType == WorkspaceRecordType.attachmentEvidenceQuotaLedger,
            priorLedger.schemaVersion == 1,
            let decoded = try? CanonicalJSONCoding.decode(AttachmentEvidenceQuotaLedger.self, from: priorLedger.encodedRecord),
            decoded.resourceKey == key
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(key)
        }
        return decoded
    }
}

struct AttachmentEvidenceActivationInputs {
    let binding: AttachmentEvidenceBindingRecord
    let release: AttachmentEvidenceReservationRelease
    let ledger: AttachmentEvidenceQuotaLedger
}
