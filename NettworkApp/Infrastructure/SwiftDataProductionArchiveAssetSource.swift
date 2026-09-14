import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum ProductionArchiveAssetSourceError: Error, Equatable, Sendable {
    case malformedAssetRecord(ResourceKey)
    case duplicateAsset(ObjectID)
    case corruptAsset(ObjectID)
}

/// Enumerates every visible, verified record-owned archive asset. Generic
/// workspace assets and attachment-evidence bytes have separate owners so a
/// restore can attach evidence bytes back to the binding envelope that commits
/// their provenance and receipt identity.
struct SwiftDataProductionArchiveAssetSource: ProductionArchiveAssetSource {
    private let persistence: SwiftDataPersistenceStore

    init(persistence: SwiftDataPersistenceStore) {
        self.persistence = persistence
    }

    func assets(in namespace: PersistenceNamespace) async throws -> [ProductionArchiveAsset] {
        let records = try await persistence.mirroredRecords(in: namespace)
            .filter {
                !$0.isTombstone
            }
            .sorted { $0.resourceKey < $1.resourceKey }
        var identities = Set<ObjectID>()
        var result: [ProductionArchiveAsset] = []
        result.reserveCapacity(records.count)
        for record in records {
            if let asset = try await archiveAsset(for: record, namespace: namespace, identities: &identities) {
                result.append(asset)
            }
        }
        return result
    }

    private func archiveAsset(
        for record: LocalMirrorRecord, namespace: PersistenceNamespace, identities: inout Set<ObjectID>
    ) async throws -> ProductionArchiveAsset? {
        switch record.recordType {
        case CloudRecordNaming.workspaceAssetRecordType:
            return try await workspaceAsset(record, namespace: namespace, identities: &identities)
        case CloudRecordNaming.attachmentEvidenceBindingRecordType:
            return try await evidenceAsset(record, namespace: namespace, identities: &identities)
        case CloudRecordNaming.floorPlanAssetBindingRecordType:
            return try await floorPlanAsset(record, namespace: namespace, identities: &identities)
        default:
            guard record.recordAssetMetadata == nil else { throw ProductionArchiveAssetSourceError.malformedAssetRecord(record.resourceKey) }
            return nil
        }
    }

    private func workspaceAsset(
        _ record: LocalMirrorRecord, namespace: PersistenceNamespace, identities: inout Set<ObjectID>
    ) async throws -> ProductionArchiveAsset {
        guard let payload = record.payload,
            let asset = canonicalDecoded(CloudWorkspaceAssetRecord.self, from: payload),
            asset.resourceKey == record.resourceKey,
            asset.metadata == record.recordAssetMetadata,
            asset.relativePath.hasPrefix(ArchiveLayout.assetsDirectory + "/"),
            !asset.relativePath.hasPrefix(ArchiveLayout.assetsDirectory + "/attachment-evidence/"),
            !asset.relativePath.hasPrefix(ArchiveLayout.assetsDirectory + "/floor-plans/")
        else {
            throw ProductionArchiveAssetSourceError.malformedAssetRecord(record.resourceKey)
        }
        try insertIdentity(asset.assetID, into: &identities)
        let bytes = try await verifiedBytes(for: asset.metadata, namespace: namespace)
        return ProductionArchiveAsset(
            assetID: asset.assetID, stableID: ArchiveAsset.stableID(for: asset.relativePath),
            relativePath: asset.relativePath, contentType: asset.metadata.contentType, bytes: bytes, owner: .workspaceAsset)
    }

    private func evidenceAsset(
        _ record: LocalMirrorRecord, namespace: PersistenceNamespace, identities: inout Set<ObjectID>
    ) async throws -> ProductionArchiveAsset {
        guard let payload = record.payload,
            let binding = canonicalDecoded(AttachmentEvidenceBindingRecord.self, from: payload),
            binding.resourceKey == record.resourceKey,
            binding.assetMetadata == record.recordAssetMetadata,
            binding.auditEventID == AuditEvent.deterministicID(for: binding.operationID)
        else {
            throw ProductionArchiveAssetSourceError.malformedAssetRecord(record.resourceKey)
        }
        try insertIdentity(binding.attachmentID, into: &identities)
        _ = try AttachmentEvidenceBindingRecord(
            workOrderID: binding.workOrderID, attachmentID: binding.attachmentID,
            reservationID: binding.reservationID, provenance: binding.provenance, evidence: binding.evidence, assetMetadata: binding.assetMetadata,
            intentDigest: binding.intentDigest, operationID: binding.operationID, auditEventID: binding.auditEventID, boundAt: binding.boundAt)
        let bytes = try await verifiedBytes(for: binding.assetMetadata, namespace: namespace)
        guard AttachmentEvidenceBindingRecord.evidenceDigest(for: bytes) == binding.provenance.domainSeparatedSHA256 else {
            throw ProductionArchiveAssetSourceError.corruptAsset(binding.attachmentID)
        }
        let path = ArchiveLayout.assetsDirectory + "/attachment-evidence/" + binding.attachmentID.description + ".jpg"
        return ProductionArchiveAsset(
            assetID: binding.attachmentID, stableID: ArchiveAsset.stableID(for: path), relativePath: path,
            contentType: binding.assetMetadata.contentType, bytes: bytes, owner: .attachmentEvidence(binding))
    }

    private func floorPlanAsset(
        _ record: LocalMirrorRecord, namespace: PersistenceNamespace, identities: inout Set<ObjectID>
    ) async throws -> ProductionArchiveAsset {
        guard let payload = record.payload,
            let binding = canonicalDecoded(FloorPlanAssetBindingRecord.self, from: payload),
            binding.resourceKey == record.resourceKey,
            binding.assetMetadata == record.recordAssetMetadata,
            binding.auditEventID == AuditEvent.deterministicID(for: binding.operationID)
        else {
            throw ProductionArchiveAssetSourceError.malformedAssetRecord(record.resourceKey)
        }
        try insertIdentity(binding.assetMetadata.id, into: &identities)
        let bytes = try await verifiedBytes(for: binding.assetMetadata, namespace: namespace)
        let path = ArchiveLayout.assetsDirectory + "/floor-plans/" + binding.floorID.description + ".jpg"
        return ProductionArchiveAsset(
            assetID: binding.assetMetadata.id, stableID: ArchiveAsset.stableID(for: path), relativePath: path,
            contentType: binding.assetMetadata.contentType, bytes: bytes, owner: .floorPlan(binding))
    }

    private func insertIdentity(_ id: ObjectID, into identities: inout Set<ObjectID>) throws {
        guard identities.insert(id).inserted else { throw ProductionArchiveAssetSourceError.duplicateAsset(id) }
    }

    private func verifiedBytes(for metadata: CloudRecordAssetMetadata, namespace: PersistenceNamespace) async throws -> Data {
        let bytes = try await persistence.data(for: metadata.id, namespace: namespace)
        guard bytes.count == metadata.byteCount,
            CloudRecordAssetDescriptor.sha256(for: bytes) == metadata.sha256
        else {
            throw ProductionArchiveAssetSourceError.corruptAsset(metadata.id)
        }
        return bytes
    }
}
