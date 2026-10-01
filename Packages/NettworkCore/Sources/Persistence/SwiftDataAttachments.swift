import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func reconcileAttachmentEvidenceFromMirror(
        candidates: Set<ResourceKey> = [],
        namespace: PersistenceNamespace
    ) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            guard !candidates.isEmpty else { return }
            // V9 repair callers supply only owner-index-derived binding keys.
            // This exact receipt projection supports prior-batch receipts and
            // deliberately avoids the legacy namespace mirror reconstruction.
            let exactRecords = try candidates.compactMap { try storedLocalMirror(for: $0, in: namespace) }
            try projectAttachmentEvidenceFromMirrorBatch(exactRecords, in: namespace)
        }
    }

    /// Runs inside `applyVerifiedMirrorBatch` after mirror/index replacement.
    /// Every receipt is an exact key lookup, so an evidence binding can refer
    /// to a prior batch without scanning the mirror. Any failure rolls back
    /// the mirror transaction rather than surfacing after Cloud acceptance.
    func projectAttachmentEvidenceFromMirrorBatch(
        _ records: [LocalMirrorRecord],
        in namespace: PersistenceNamespace
    ) throws {
        for record in records { try projectAttachmentEvidence(record, in: namespace) }
    }

    func projectAttachmentEvidence(_ record: LocalMirrorRecord, in namespace: PersistenceNamespace) throws {
        guard !record.isTombstone, record.recordType == WorkspaceRecordType.attachmentEvidenceBinding else { return }
        let binding = try attachmentEvidenceBinding(record)
        let receipt = try attachmentEvidenceReceipt(for: binding, in: namespace)
        try validateAttachment(for: binding, in: namespace)
        let metadata = try attachmentEvidenceMetadata(binding: binding, receipt: receipt, namespace: namespace)
        try storeAttachmentEvidence(metadata, attachmentID: binding.attachmentID, in: namespace)
        try removeAttachmentEvidenceReservation(binding.attachmentID, in: namespace)
    }

    func attachmentEvidenceBinding(_ record: LocalMirrorRecord) throws -> AttachmentEvidenceBindingRecord {
        guard let payload = record.payload else { throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey) }
        let binding = try MirroredAuthoritativeCoding.decode(AttachmentEvidenceBindingRecord.self, from: payload)
        guard binding.resourceKey == record.resourceKey else { throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey) }
        return binding
    }

    func attachmentEvidenceReceipt(for binding: AttachmentEvidenceBindingRecord, in namespace: PersistenceNamespace) throws -> OperationReceipt {
        let key = ResourceKey.operationReceipt(operationID: binding.operationID)
        guard let record = try storedLocalMirror(for: key, in: namespace), !record.isTombstone, record.recordType == WorkspaceRecordType.operationReceipt,
            let payload = record.payload
        else { throw PersistenceStoreError.invalidReceipt(binding.operationID) }
        let receipt = try MirroredAuthoritativeCoding.decode(OperationReceipt.self, from: payload)
        guard receipt.operationID == binding.operationID, receipt.intentDigest == binding.intentDigest, receipt.auditEventID == binding.auditEventID else {
            throw PersistenceStoreError.invalidReceipt(binding.operationID)
        }
        return receipt
    }

    func validateAttachment(for binding: AttachmentEvidenceBindingRecord, in namespace: PersistenceNamespace) throws {
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "attachment:\(binding.attachmentID.description)")
        guard let attachment = try attachmentModel(matching: key), attachment.contentType == binding.provenance.contentType,
            attachment.byteCount == binding.provenance.byteCount
        else { throw PersistenceStoreError.missingAttachment(binding.attachmentID) }
    }

    func attachmentEvidenceMetadata(binding: AttachmentEvidenceBindingRecord, receipt: OperationReceipt, namespace: PersistenceNamespace) throws
        -> AttachmentEvidenceMetadata
    {
        let provenance = try SanitizedAttachmentProvenance(
            domainSeparatedSHA256: binding.provenance.domainSeparatedSHA256, purpose: binding.provenance.purpose, contentType: binding.provenance.contentType,
            byteCount: binding.provenance.byteCount)
        return try AttachmentEvidenceMetadata(
            namespace: namespace, workOrderID: binding.workOrderID, attachmentID: binding.attachmentID, reservationID: binding.reservationID,
            provenance: provenance,
            evidence: binding.evidence, receipt: receipt, boundAt: binding.boundAt)
    }

    func storeAttachmentEvidence(_ metadata: AttachmentEvidenceMetadata, attachmentID: ObjectID, in namespace: PersistenceNamespace) throws {
        let key = attachmentEvidenceStorageKey(attachmentID: attachmentID, namespace: namespace)
        guard let existing = try attachmentEvidenceModel(matching: key) else {
            modelContext.insert(try LocalAttachmentEvidenceModel(metadata: metadata))
            return
        }
        guard try decodeAttachmentEvidence(existing, namespace: namespace) == metadata else {
            throw AttachmentEvidencePersistenceError.attachmentAlreadyBound(attachmentID)
        }
    }

    func removeAttachmentEvidenceReservation(_ attachmentID: ObjectID, in namespace: PersistenceNamespace) throws {
        let key = attachmentEvidenceReservationStorageKey(attachmentID: attachmentID, namespace: namespace)
        if let reservation = try attachmentEvidenceReservationModel(matching: key) { modelContext.delete(reservation) }
    }

    public func releaseAttachmentEvidenceReservation(id: ObjectID, namespace: PersistenceNamespace) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            let models = try attachmentEvidenceReservationModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            guard let model = models.first(where: { $0.reservationID == id.description }) else { return }
            modelContext.delete(model)
        }
    }

    public func store(_ data: Data, contentType: String, namespace: PersistenceNamespace) async throws -> ObjectID {
        try validateActiveLease(for: namespace)
        let normalizedType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedType.isEmpty else { throw PersistenceStoreError.invalidNamespace }
        let id = ObjectID()
        let relativePath = try await attachmentFiles.write(data, id: id, namespace: namespace)
        do {
            try transaction {
                try validateActiveLease(for: namespace)
                modelContext.insert(
                    LocalAttachmentModel(
                        id: id, namespace: namespace, contentType: normalizedType, relativePath: relativePath, byteCount: data.count, createdAt: .now))
            }
            return id
        } catch {
            try? await attachmentFiles.remove(relativePath: relativePath, id: id)
            throw error
        }
    }

    public func data(for id: ObjectID, namespace: PersistenceNamespace) async throws -> Data {
        try validateActiveLease(for: namespace)
        let associatedRecords = try mirrorModels(
            namespaceKey: PersistenceNamespaceKey.value(for: namespace)
        ).map { try decodeMirror($0, namespace: namespace) }.filter { $0.recordAssetMetadata?.id == id }
        if !associatedRecords.isEmpty,
            try !associatedRecords.contains(where: { try isVisibleToFeatureProjection($0, in: namespace) })
        {
            throw PersistenceStoreError.missingAttachment(id)
        }
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "attachment:\(id.description)")
        guard let model = try attachmentModel(matching: key) else { throw PersistenceStoreError.missingAttachment(id) }
        let data = try await attachmentFiles.read(relativePath: model.relativePath, id: id, expectedByteCount: model.byteCount)
        try validateActiveLease(for: namespace)
        return data
    }

    public func remove(id: ObjectID, namespace: PersistenceNamespace) async throws {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "attachment:\(id.description)")
        guard let model = try attachmentModel(matching: key) else { throw PersistenceStoreError.missingAttachment(id) }
        let relativePath = model.relativePath
        try transaction {
            try validateActiveLease(for: namespace)
            modelContext.delete(model)
        }
        try await attachmentFiles.remove(relativePath: relativePath, id: id)
    }

    // MARK: MutationOutbox
}
