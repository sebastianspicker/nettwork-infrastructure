import CloudSync
import ContentSafety
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// Reviewed organization policy supplied at composition time. There are no
/// product defaults for retention or quota: deployment must inject approved
/// limits and a version that appears in the immutable activation audit.
struct ProductionAttachmentEvidencePolicy: Sendable {
    let quota: AttachmentEvidenceQuotaPolicy
    let policyVersion: String

    init(quota: AttachmentEvidenceQuotaPolicy, policyVersion: String) throws {
        let version = policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw ProductionAttachmentEvidenceAuthorityError.invalidPolicy }
        self.quota = quota
        self.policyVersion = version
    }
}

enum ProductionAttachmentEvidenceAuthorityError: Error, Equatable, Sendable {
    case invalidPolicy
    case namespaceMismatch
    case invalidReservation
    case expiredReservation
    case invalidWorkOrder
    case workOrderOwnershipMismatch
    case evidenceNotBoundToWorkOrderIntent
    case malformedAuthoritativeRecord(ResourceKey)
    case quotaExceeded
    case receiptMismatch
}

/// Production F02 authority. Sanitization remains in ContentSafety, quota and
/// cache metadata remain in Persistence, and this actor alone turns a valid
/// reservation into one conditional activation through the existing mutation
/// repository. It never performs a direct CloudKit write: the sanitized bytes
/// travel on the binding save and CloudSync materializes them as that record's
/// CKAsset inside the same atomic operation.
actor ProductionAttachmentEvidenceAuthority: AttachmentEvidenceReservationAuthority {
    let sessionAuthorizer: ProductionSessionAuthorizer
    let exactRecords: any CloudExactRecordReading
    let mutations: any AuthoritativeMutationRepository
    let persistence: SwiftDataPersistenceStore
    let policy: ProductionAttachmentEvidencePolicy
    let now: @Sendable () -> Date
    /// Once CloudKit has accepted the activation, a best-effort caller release
    /// must not delete the only local sanitized copy if durable-cache recording
    /// subsequently reports an error.
    private var committedReservationIDs = Set<ObjectID>()

    init(
        sessionAuthorizer: ProductionSessionAuthorizer,
        exactRecords: any CloudExactRecordReading,
        mutations: any AuthoritativeMutationRepository,
        persistence: SwiftDataPersistenceStore,
        policy: ProductionAttachmentEvidencePolicy,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.sessionAuthorizer = sessionAuthorizer
        self.exactRecords = exactRecords
        self.mutations = mutations
        self.persistence = persistence
        self.policy = policy
        self.now = now
    }

    func reserveAttachment(owner: AttachmentEvidenceOwner, attachment: VerifiedSanitizedAttachment) async throws -> AttachmentQuotaReservation {
        guard owner.matches(attachment.namespace),
            attachment.purpose == .evidence,
            attachment.contentType == .jpeg,
            attachment.byteCount > 0
        else {
            throw AttachmentEvidenceBindingError.invalidOwner
        }
        let reservation = try await persistence.reserveAttachmentEvidence(
            workOrderID: owner.workOrderID,
            attachmentID: attachment.attachmentID,
            byteCount: attachment.byteCount,
            policy: policy.quota,
            namespace: owner.namespace,
            at: now()
        )
        return AttachmentQuotaReservation(
            id: reservation.id, owner: owner, attachmentID: reservation.attachmentID, reservedCount: reservation.reservedCount,
            reservedBytes: reservation.reservedBytes, expiresAt: reservation.expiresAt
        )
    }

    func bindReservedAttachment(
        _ reservation: AttachmentQuotaReservation, attachment: VerifiedSanitizedAttachment, intent: AttachmentEvidenceBindingIntent,
        authorization: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        try validateBindingRequest(reservation, attachment: attachment, intent: intent, authorization: authorization)
        let preparation = try await prepareBinding(reservation, attachment: attachment, intent: intent, authorization: authorization)
        let mutation = try makeActivationMutation(reservation, attachment: attachment, intent: intent, authorization: authorization, preparation: preparation)
        try await sessionAuthorizer.revalidate(preparation.trusted)
        let committedReceipt = try await mutations.commit(mutation)
        guard committedReceipt == intent.expectedReceipt else {
            throw ProductionAttachmentEvidenceAuthorityError.receiptMismatch
        }
        committedReservationIDs.insert(reservation.id)
        await cacheCommittedBinding(reservation, preparation: preparation, intent: intent, receipt: committedReceipt)
        return committedReceipt
    }

    func releaseAttachmentReservation(_ reservation: AttachmentQuotaReservation) async {
        guard !committedReservationIDs.contains(reservation.id) else { return }
        try? await persistence.releaseAttachmentEvidenceReservation(id: reservation.id, namespace: reservation.owner.namespace)
        guard
            (try? await persistence.attachmentEvidence(
                for: reservation.attachmentID,
                namespace: reservation.owner.namespace
            )) == nil
        else {
            return
        }
        try? await persistence.remove(id: reservation.attachmentID, namespace: reservation.owner.namespace)
    }

    func requiredExactRecord(_ key: ResourceKey, recordType: String, namespace: PersistenceNamespace) async throws -> CloudExactRecordSnapshot {
        guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone),
            snapshot.workspaceZone == namespace.workspaceZone,
            snapshot.resourceKey == key,
            snapshot.recordType == recordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            !snapshot.exactPrecondition.systemFields.isEmpty,
            !snapshot.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProductionAttachmentEvidenceAuthorityError.malformedAuthoritativeRecord(key)
        }
        return snapshot
    }

    func currentLedger(
        for workOrderID: ObjectID, namespace: PersistenceNamespace
    ) async throws -> (value: AttachmentEvidenceQuotaLedger, exact: ExactRecordPrecondition?) {
        let key = ResourceKey.attachmentEvidenceQuotaLedger(for: workOrderID)
        guard let snapshot = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone) else {
            return (try AttachmentEvidenceQuotaLedger(workOrderID: workOrderID, updatedAt: now()), nil)
        }
        guard snapshot.workspaceZone == namespace.workspaceZone,
            snapshot.resourceKey == key,
            snapshot.recordType == CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType,
            snapshot.schemaVersion == CloudRecordNaming.schemaVersion,
            !snapshot.exactPrecondition.systemFields.isEmpty,
            !snapshot.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let ledger = try? CloudDeterministicCoding.decode(AttachmentEvidenceQuotaLedger.self, from: snapshot.payload),
            ledger.resourceKey == key
        else {
            throw ProductionAttachmentEvidenceAuthorityError.malformedAuthoritativeRecord(key)
        }
        return (ledger, snapshot.exactPrecondition)
    }

    func activationSaves(
        sentinel: CloudExactRecordSnapshot, ledger: AttachmentEvidenceQuotaLedger, release: AttachmentEvidenceReservationRelease,
        binding: AttachmentEvidenceBindingRecord, recordAsset: CloudRecordAssetDescriptor
    ) throws -> [AuthoritativeRecordSave] {
        [
            AuthoritativeRecordSave(
                resourceKey: sentinel.resourceKey, recordType: sentinel.recordType, schemaVersion: sentinel.schemaVersion, encodedRecord: sentinel.payload
            ),
            AuthoritativeRecordSave(
                resourceKey: ledger.resourceKey,
                recordType: CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                encodedRecord: try CloudDeterministicCoding.encode(ledger)
            ),
            AuthoritativeRecordSave(
                resourceKey: release.resourceKey,
                recordType: CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                encodedRecord: try CloudDeterministicCoding.encode(release)
            ),
            AuthoritativeRecordSave(
                resourceKey: binding.resourceKey,
                recordType: CloudRecordNaming.attachmentEvidenceBindingRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                encodedRecord: try CloudDeterministicCoding.encode(binding),
                recordAsset: recordAsset
            ),
        ]
    }

    func activationPreconditions(
        sentinel: CloudExactRecordSnapshot, workOrder: CloudExactRecordSnapshot, ledger: ExactRecordPrecondition?,
        release: AttachmentEvidenceReservationRelease, binding: AttachmentEvidenceBindingRecord, auditID: ObjectID, receipt: OperationReceipt
    ) -> [MutationPrecondition] {
        [
            .exactSystemFields(sentinel.resourceKey, sentinel.exactPrecondition),
            .exactSystemFields(workOrder.resourceKey, workOrder.exactPrecondition),
            ledger.map { .exactSystemFields(.attachmentEvidenceQuotaLedger(for: binding.workOrderID), $0) }
                ?? .mustNotExist(.attachmentEvidenceQuotaLedger(for: binding.workOrderID)),
            .mustNotExist(release.resourceKey),
            .mustNotExist(binding.resourceKey),
            .mustNotExist(.object(auditID)),
            .mustNotExist(receipt.id),
        ]
    }
}
