import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataCloudMirrorStore {
    public func applyVerifiedBatch(_ records: [VerifiedCloudRecord], syncState: Data, namespace: PersistenceNamespace) async throws {
        let lease = try requireOpen(namespace)
        let now = Date.now
        let localRecords = localMirrorRecords(records, namespace: namespace, now: now)
        let candidateKeys = Set(localRecords.map(\.resourceKey))
        let storedBefore = try await persistence.storedLocalMirrors(for: candidateKeys, in: namespace)
        let cleanupCandidates = attachmentCleanupCandidates(storedBefore, records: records)
        let maintenance = try CloudMirrorMaintenanceFactBuilder.build(for: records)
        try await validateAssetAdmission(
            incoming: records, replacing: storedBefore,
            maintenance: maintenance, namespace: namespace)
        do {
            try await stageVerifiedAssets(records, namespace: namespace)
            try await apply(localRecords, syncState: syncState, maintenance: maintenance, namespace: namespace, lease: lease, now: now)
            // Mirror/index/evidence projection has already committed. Cleanup
            // is best effort only; durable staging markers retain exact retry
            // candidates and must not turn an accepted mirror batch into an
            // observable error.
            _ = try? await persistence.reconcileVerifiedMirrorAttachments(
                candidates: cleanupCandidates,
                namespace: namespace)
        } catch {
            _ = try? await persistence.reconcileVerifiedMirrorAttachments(
                candidates: cleanupCandidates,
                namespace: namespace)
            throw error
        }
    }

    private func localMirrorRecords(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace, now: Date) -> [LocalMirrorRecord] {
        records.map { verified in
            let envelope = verified.envelope
            return LocalMirrorRecord(
                namespace: namespace, resourceKey: envelope.resourceKey, recordType: persistenceRecordType(for: envelope.recordType),
                schemaVersion: envelope.schemaVersion, payload: envelope.payload,
                systemFields: envelope.systemFields, changeTag: envelope.changeTag, isTombstone: envelope.isDeleted, visibility: envelope.visibility,
                recordAssetMetadata: envelope.recordAsset?.metadata,
                serverModifiedAt: now, verifiedAt: now)
        }
    }

    private func attachmentCleanupCandidates(_ records: [LocalMirrorRecord], records incoming: [VerifiedCloudRecord]) -> Set<ObjectID> {
        Set(records.compactMap(\.recordAssetMetadata?.id)).union(incoming.compactMap { $0.envelope.recordAsset?.metadata.id })
    }

    private func stageVerifiedAssets(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws {
        for verified in records where !verified.envelope.isDeleted {
            try await stageWorkspaceAsset(verified.envelope, namespace: namespace)
            try await stageEvidenceAsset(verified.envelope, namespace: namespace)
            try await stageFloorAsset(verified.envelope, namespace: namespace)
        }
    }

    private func stageWorkspaceAsset(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) async throws {
        guard envelope.recordType == CloudRecordNaming.workspaceAssetRecordType, let asset = envelope.recordAsset else { return }
        try await persistence.stageVerifiedMirrorAttachment(
            try asset.validatedBytes(), id: asset.metadata.id, contentType: asset.contentType, namespace: namespace)
    }

    private func stageEvidenceAsset(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) async throws {
        guard envelope.recordType == CloudRecordNaming.attachmentEvidenceBindingRecordType else { return }
        let binding = try CloudDeterministicCoding.decode(AttachmentEvidenceBindingRecord.self, from: envelope.payload)
        _ = try AttachmentEvidenceBindingRecord(
            workOrderID: binding.workOrderID, attachmentID: binding.attachmentID, reservationID: binding.reservationID, provenance: binding.provenance,
            evidence: binding.evidence,
            assetMetadata: binding.assetMetadata, intentDigest: binding.intentDigest, operationID: binding.operationID, auditEventID: binding.auditEventID,
            boundAt: binding.boundAt)
        guard let asset = envelope.recordAsset else {
            throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, "attachment evidence asset binding")
        }
        let bytes = try asset.validatedBytes()
        guard asset.metadata == binding.assetMetadata, asset.metadata.id == binding.attachmentID, asset.contentType == binding.provenance.contentType,
            asset.byteCount == binding.provenance.byteCount,
            AttachmentEvidenceBindingRecord.evidenceDigest(for: bytes) == binding.provenance.domainSeparatedSHA256
        else { throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, "attachment evidence asset binding") }
        try await persistence.stageVerifiedMirrorAttachment(bytes, id: binding.attachmentID, contentType: asset.contentType, namespace: namespace)
    }

    private func stageFloorAsset(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) async throws {
        guard envelope.recordType == CloudRecordNaming.floorPlanAssetBindingRecordType else { return }
        let binding = try CloudDeterministicCoding.decode(FloorPlanAssetBindingRecord.self, from: envelope.payload)
        _ = try FloorPlanAssetBindingRecord(
            floorID: binding.floorID, workOrderID: binding.workOrderID, assetMetadata: binding.assetMetadata, intentDigest: binding.intentDigest,
            operationID: binding.operationID,
            auditEventID: binding.auditEventID, boundAt: binding.boundAt)
        guard let asset = envelope.recordAsset, asset.metadata == binding.assetMetadata, asset.metadata.id == binding.assetMetadata.id,
            asset.contentType == binding.assetMetadata.contentType,
            asset.byteCount == binding.assetMetadata.byteCount, (try? asset.validatedBytes()) != nil
        else { throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, "floor-plan asset binding") }
        try await persistence.stageVerifiedMirrorAttachment(
            try asset.validatedBytes(), id: binding.assetMetadata.id, contentType: asset.contentType, namespace: namespace)
    }

    private func apply(
        _ records: [LocalMirrorRecord], syncState: Data, maintenance: LocalMirrorMaintenanceBatch, namespace: PersistenceNamespace,
        lease: PersistenceNamespaceLease, now: Date
    ) async throws {
        let visibility = try await deriveWorkspaceVisibilityIndexed(applying: records, maintenance: maintenance, namespace: namespace)
        let state = LocalSyncState(namespace: namespace, engineState: syncState, changeToken: nil, lastSuccessfulServerContact: now, updatedAt: now)
        try await persistence.applyVerifiedMirrorBatch(
            LocalMirrorBatch(records: records, syncState: state, workspaceVisibility: visibility, maintenance: maintenance), in: namespace, lease: lease)
    }
}
