import CloudSync
import ContentSafety
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

struct AttachmentEvidenceBindingPreparation {
    let trusted: TrustedProductionSession
    let durableReservation: AttachmentEvidenceReservationMetadata
    let provenance: SanitizedAttachmentProvenance
    let authoritativeProvenance: AttachmentEvidenceProvenanceRecord
    let workOrderSnapshot: CloudExactRecordSnapshot
    let workOrder: WorkOrder
    let sentinel: CloudExactRecordSnapshot
    let ledger: AttachmentEvidenceQuotaLedger
    let ledgerExact: ExactRecordPrecondition?
    let recordAsset: CloudRecordAssetDescriptor
}

extension ProductionAttachmentEvidenceAuthority {
    func validateBindingRequest(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, intent: AttachmentEvidenceBindingIntent,
        authorization: AuthorizedOperationContext
    ) throws {
        guard authorization.action == .createAttachment,
            reservation.owner == intent.owner,
            reservation.attachmentID == attachment.attachmentID,
            reservation.attachmentID == intent.attachmentID,
            reservation.reservedCount == 1,
            reservation.reservedBytes == attachment.byteCount,
            reservation.owner.matches(attachment.namespace),
            attachment.purpose == .evidence,
            attachment.contentType == .jpeg,
            authorization.account.namespace == reservation.owner.namespace,
            intent.expectedReceipt.operationID == authorization.operationID,
            intent.expectedReceipt.workspaceZone == authorization.account.namespace.workspaceZone
        else {
            throw AttachmentEvidenceBindingError.invalidReservation
        }
    }

    func prepareBinding(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, intent: AttachmentEvidenceBindingIntent,
        authorization: AuthorizedOperationContext
    ) async throws -> AttachmentEvidenceBindingPreparation {
        let (trusted, durable) = try await authorizeReservation(reservation, attachment: attachment, authorization: authorization)
        let (provenance, authoritativeProvenance) = try makeProvenance(attachment)
        let (workOrderSnapshot, workOrder) = try await loadBindingWorkOrder(reservation, intent: intent, trusted: trusted)
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: reservation.owner.namespace.workspaceID)
        let sentinel = try await requiredExactRecord(sentinelKey, recordType: CloudRecordNaming.workspaceRecordType, namespace: reservation.owner.namespace)
        let (ledger, ledgerExact) = try await updatedLedger(reservation, attachment: attachment, trusted: trusted)
        let recordAsset = try await storeRecordAsset(attachment, namespace: reservation.owner.namespace)
        return AttachmentEvidenceBindingPreparation(
            trusted: trusted, durableReservation: durable, provenance: provenance,
            authoritativeProvenance: authoritativeProvenance, workOrderSnapshot: workOrderSnapshot, workOrder: workOrder, sentinel: sentinel,
            ledger: ledger, ledgerExact: ledgerExact, recordAsset: recordAsset)
    }

    private func authorizeReservation(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, authorization: AuthorizedOperationContext
    ) async throws -> (TrustedProductionSession, AttachmentEvidenceReservationMetadata) {
        let trusted = try await sessionAuthorizer.authorizeOperation(authorization, action: .createAttachment, requiresAdministrator: false)
        guard trusted.account.namespace == reservation.owner.namespace else {
            throw ProductionAttachmentEvidenceAuthorityError.namespaceMismatch
        }
        let durable = try await persistence.attachmentEvidenceReservation(id: reservation.id, namespace: reservation.owner.namespace, at: now())
        guard durable.workOrderID == reservation.owner.workOrderID,
            durable.attachmentID == attachment.attachmentID,
            durable.reservedCount == reservation.reservedCount,
            durable.reservedBytes == reservation.reservedBytes,
            durable.expiresAt == reservation.expiresAt
        else {
            throw ProductionAttachmentEvidenceAuthorityError.invalidReservation
        }
        guard trusted.actorSnapshot.capturedAt < durable.expiresAt else {
            throw ProductionAttachmentEvidenceAuthorityError.expiredReservation
        }
        return (trusted, durable)
    }

    private func makeProvenance(_ attachment: VerifiedSanitizedAttachment) throws -> (SanitizedAttachmentProvenance, AttachmentEvidenceProvenanceRecord) {
        let provenance = try SanitizedAttachmentProvenance(
            domainSeparatedSHA256: attachment.domainSeparatedSHA256,
            purpose: attachment.purpose.rawValue, contentType: attachment.contentType.rawValue, byteCount: attachment.byteCount)
        let authoritative = try AttachmentEvidenceProvenanceRecord(
            domainSeparatedSHA256: provenance.domainSeparatedSHA256,
            purpose: provenance.purpose, contentType: provenance.contentType, byteCount: provenance.byteCount)
        return (provenance, authoritative)
    }

    private func loadBindingWorkOrder(
        _ reservation: AttachmentQuotaReservation, intent: AttachmentEvidenceBindingIntent, trusted: TrustedProductionSession
    ) async throws -> (CloudExactRecordSnapshot, WorkOrder) {
        let snapshot = try await requiredExactRecord(
            .object(reservation.owner.workOrderID), recordType: CloudRecordNaming.workOrderRecordType,
            namespace: reservation.owner.namespace)
        let workOrder = try CloudDeterministicCoding.decode(WorkOrder.self, from: snapshot.payload)
        guard workOrder.id == reservation.owner.workOrderID,
            workOrder.evidenceHashes.contains(intent.evidence),
            let workReservation = workOrder.reservation,
            workReservation.ownerID == trusted.actorSnapshot.actorID,
            workReservation.acknowledgedByCloudKit != nil,
            trusted.actorSnapshot.capturedAt < (workReservation.acknowledgedByCloudKit?.expiresAt ?? .distantPast),
            [.reserved, .approved, .executing].contains(workOrder.status)
        else {
            throw ProductionAttachmentEvidenceAuthorityError.evidenceNotBoundToWorkOrderIntent
        }
        return (snapshot, workOrder)
    }

    private func updatedLedger(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, trusted: TrustedProductionSession
    ) async throws -> (AttachmentEvidenceQuotaLedger, ExactRecordPrecondition?) {
        let current = try await currentLedger(for: reservation.owner.workOrderID, namespace: reservation.owner.namespace)
        let updated = try current.value.consuming(byteCount: attachment.byteCount, at: trusted.actorSnapshot.capturedAt)
        guard updated.attachmentCount <= policy.quota.maximumAttachmentCount,
            updated.totalBytes <= policy.quota.maximumTotalBytes
        else {
            throw ProductionAttachmentEvidenceAuthorityError.quotaExceeded
        }
        return (updated, current.exact)
    }

    private func storeRecordAsset(_ attachment: VerifiedSanitizedAttachment, namespace: PersistenceNamespace) async throws -> CloudRecordAssetDescriptor {
        let asset = try CloudRecordAssetDescriptor(
            id: attachment.attachmentID, fieldName: "sanitizedAsset",
            sha256: CloudRecordAssetDescriptor.sha256(for: attachment.sanitizedBytes), contentType: attachment.contentType.rawValue,
            byteCount: attachment.byteCount, storage: .inline(attachment.sanitizedBytes))
        try await persistence.storeVerifiedAttachment(
            attachment.sanitizedBytes, id: attachment.attachmentID,
            contentType: attachment.contentType.rawValue, namespace: namespace)
        return asset
    }

    func makeActivationMutation(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, intent: AttachmentEvidenceBindingIntent,
        authorization: AuthorizedOperationContext, preparation: AttachmentEvidenceBindingPreparation
    ) throws -> AuthoritativeActivationMutation {
        let auditID = AuditEvent.deterministicID(for: authorization.operationID)
        let release = try makeReservationRelease(preparation, operationID: authorization.operationID)
        let binding = try makeBinding(
            reservation, attachment: attachment, intent: intent, preparation: preparation, auditID: auditID,
            operationID: authorization.operationID)
        let saves = try activationSaves(
            sentinel: preparation.sentinel, ledger: preparation.ledger, release: release, binding: binding,
            recordAsset: preparation.recordAsset)
        let assertion = readAssertion(for: preparation.workOrderSnapshot)
        let audit = makeBindingAudit(preparation, saves: saves, auditID: auditID, operationID: authorization.operationID)
        return try AuthoritativeActivationMutation(
            workspaceZone: reservation.owner.namespace.workspaceZone,
            operationID: authorization.operationID, intentDigest: intent.digest, actor: preparation.trusted.actorSnapshot, saves: saves, tombstones: [],
            preconditions: activationPreconditions(
                sentinel: preparation.sentinel, workOrder: preparation.workOrderSnapshot,
                ledger: preparation.ledgerExact, release: release, binding: binding, auditID: auditID, receipt: intent.expectedReceipt),
            readAssertions: [assertion], auditEvent: audit, receipt: intent.expectedReceipt)
    }

    private func makeReservationRelease(
        _ preparation: AttachmentEvidenceBindingPreparation, operationID: ObjectID
    ) throws -> AttachmentEvidenceReservationRelease {
        let value = preparation.durableReservation
        return try AttachmentEvidenceReservationRelease(
            id: value.id, workOrderID: value.workOrderID, attachmentID: value.attachmentID,
            reservedCount: value.reservedCount, reservedBytes: value.reservedBytes, expiresAt: value.expiresAt,
            releasedAt: preparation.trusted.actorSnapshot.capturedAt, operationID: operationID)
    }

    private func makeBinding(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, intent: AttachmentEvidenceBindingIntent,
        preparation: AttachmentEvidenceBindingPreparation, auditID: ObjectID, operationID: ObjectID
    ) throws -> AttachmentEvidenceBindingRecord {
        try AttachmentEvidenceBindingRecord(
            workOrderID: reservation.owner.workOrderID, attachmentID: attachment.attachmentID,
            reservationID: preparation.durableReservation.id, provenance: preparation.authoritativeProvenance, evidence: intent.evidence,
            assetMetadata: preparation.recordAsset.metadata, intentDigest: intent.digest, operationID: operationID, auditEventID: auditID,
            boundAt: preparation.trusted.actorSnapshot.capturedAt)
    }

    private func readAssertion(for snapshot: CloudExactRecordSnapshot) -> AuthoritativeReadAssertion {
        AuthoritativeReadAssertion(
            resourceKey: snapshot.resourceKey, recordType: snapshot.recordType, schemaVersion: snapshot.schemaVersion,
            encodedRecord: snapshot.payload, precondition: snapshot.exactPrecondition)
    }

    private func makeBindingAudit(
        _ preparation: AttachmentEvidenceBindingPreparation, saves: [AuthoritativeRecordSave], auditID: ObjectID, operationID: ObjectID
    ) -> AuditEvent {
        AuditEvent(
            id: auditID, operationID: operationID, actorID: preparation.trusted.actorSnapshot.actorID,
            affectedObjectIDs: AuthoritativeAuditSupport.objectIDs(in: saves), workOrderID: preparation.workOrder.id,
            occurredAt: preparation.trusted.actorSnapshot.capturedAt, result: .accepted, installationID: preparation.trusted.actorSnapshot.installationID,
            sessionID: preparation.trusted.actorSnapshot.sessionID, sessionGeneration: preparation.trusted.actorSnapshot.sessionGeneration,
            source: .interactive, affectedResourceKeys: saves.map(\.resourceKey).sorted(),
            changes: saves.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord) }.sorted { $0.resourceKey < $1.resourceKey },
            ticket: preparation.workOrder.ticket, policyVersion: policy.policyVersion)
    }

    func cacheCommittedBinding(
        _ reservation: AttachmentQuotaReservation, preparation: AttachmentEvidenceBindingPreparation,
        intent: AttachmentEvidenceBindingIntent, receipt: OperationReceipt
    ) async {
        _ = try? await persistence.bindAttachmentEvidence(
            reservationID: reservation.id, provenance: preparation.provenance,
            evidence: intent.evidence, receipt: receipt, expectedReceipt: intent.expectedReceipt, namespace: reservation.owner.namespace,
            at: preparation.trusted.actorSnapshot.capturedAt)
    }
}

enum AuthoritativeAuditSupport {
    static func objectIDs(in saves: [AuthoritativeRecordSave]) -> [ObjectID] {
        saves.compactMap { save in
            guard case let .object(id) = save.resourceKey else { return nil }
            return id
        }.sorted()
    }
}
