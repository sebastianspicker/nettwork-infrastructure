import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func archiveAssets(in namespace: PersistenceNamespace, records: [LocalMirrorRecord]) async throws -> [ArchiveAssetPayload] {
        var catalog = try ArchiveAssetCatalog(records: records)
        let supplied = try await assetSource.assets(in: namespace)
        var paths = Set<String>()
        var result: [ArchiveAssetPayload] = []
        for asset in supplied {
            result.append(try catalog.archivePayload(for: asset, paths: &paths))
        }
        try catalog.requireComplete()
        return result.sorted { $0.relativePath < $1.relativePath }
    }
}

private struct ArchiveAssetCatalog {
    private var workspaceAssets: [ObjectID: CloudWorkspaceAssetRecord] = [:]
    private var evidenceBindings: [ObjectID: AttachmentEvidenceBindingRecord] = [:]
    private var floorPlanBindings: [ObjectID: FloorPlanAssetBindingRecord] = [:]

    init(records: [LocalMirrorRecord]) throws {
        for record in records where !record.isTombstone {
            try absorb(record)
        }
    }

    mutating func archivePayload(for suppliedAsset: ProductionArchiveAsset, paths: inout Set<String>) throws -> ArchiveAssetPayload {
        let path = try normalizedPath(for: suppliedAsset, paths: &paths)
        switch suppliedAsset.owner {
        case .workspaceAsset:
            try validateWorkspaceAsset(suppliedAsset, path: path)
        case let .attachmentEvidence(binding):
            try validateEvidenceBinding(suppliedAsset, binding: binding, path: path)
        case let .floorPlan(binding):
            try validateFloorPlanBinding(suppliedAsset, binding: binding, path: path)
        }
        return ArchiveAssetPayload(
            id: suppliedAsset.assetID, stableID: suppliedAsset.stableID, relativePath: path, contentType: suppliedAsset.contentType, bytes: suppliedAsset.bytes
        )
    }

    func requireComplete() throws {
        guard workspaceAssets.isEmpty,
            evidenceBindings.isEmpty,
            floorPlanBindings.isEmpty
        else {
            throw ProductionWorkspaceTransferAuthorityError.missingArchiveAsset
        }
    }

    private mutating func absorb(_ record: LocalMirrorRecord) throws {
        switch record.recordType {
        case CloudRecordNaming.workspaceAssetRecordType:
            try absorbWorkspaceAsset(record)
        case CloudRecordNaming.attachmentEvidenceBindingRecordType:
            try absorbEvidenceBinding(record)
        case CloudRecordNaming.floorPlanAssetBindingRecordType:
            try absorbFloorPlanBinding(record)
        default:
            guard record.recordAssetMetadata == nil else {
                throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
            }
        }
    }

    private mutating func absorbWorkspaceAsset(_ record: LocalMirrorRecord) throws {
        guard let payload = record.payload,
            let asset = canonicalDecoded(CloudWorkspaceAssetRecord.self, from: payload),
            asset.resourceKey == record.resourceKey,
            asset.metadata == record.recordAssetMetadata,
            !asset.relativePath.hasPrefix(ProductionWorkspaceTransferAuthority.attachmentEvidenceAssetsDirectory + "/"),
            !asset.relativePath.hasPrefix(ProductionWorkspaceTransferAuthority.floorPlanAssetsDirectory + "/"),
            workspaceAssets[asset.assetID] == nil,
            evidenceBindings[asset.assetID] == nil
        else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
        }
        workspaceAssets[asset.assetID] = asset
    }

    private mutating func absorbEvidenceBinding(_ record: LocalMirrorRecord) throws {
        guard let payload = record.payload,
            let binding = canonicalDecoded(AttachmentEvidenceBindingRecord.self, from: payload),
            binding.resourceKey == record.resourceKey,
            binding.assetMetadata == record.recordAssetMetadata,
            binding.auditEventID == AuditEvent.deterministicID(for: binding.operationID),
            evidenceBindings[binding.attachmentID] == nil,
            workspaceAssets[binding.attachmentID] == nil
        else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
        }
        _ = try AttachmentEvidenceBindingRecord(
            workOrderID: binding.workOrderID, attachmentID: binding.attachmentID, reservationID: binding.reservationID,
            provenance: binding.provenance, evidence: binding.evidence, assetMetadata: binding.assetMetadata,
            intentDigest: binding.intentDigest, operationID: binding.operationID, auditEventID: binding.auditEventID, boundAt: binding.boundAt
        )
        evidenceBindings[binding.attachmentID] = binding
    }

    private mutating func absorbFloorPlanBinding(_ record: LocalMirrorRecord) throws {
        guard let payload = record.payload,
            let binding = canonicalDecoded(FloorPlanAssetBindingRecord.self, from: payload),
            binding.resourceKey == record.resourceKey,
            binding.assetMetadata == record.recordAssetMetadata,
            binding.auditEventID == AuditEvent.deterministicID(for: binding.operationID),
            floorPlanBindings[binding.assetMetadata.id] == nil,
            evidenceBindings[binding.assetMetadata.id] == nil,
            workspaceAssets[binding.assetMetadata.id] == nil
        else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
        }
        floorPlanBindings[binding.assetMetadata.id] = binding
    }

    private func normalizedPath(for suppliedAsset: ProductionArchiveAsset, paths: inout Set<String>) throws -> String {
        let path = try ArchivePathPolicy.normalized(suppliedAsset.relativePath)
        guard path == suppliedAsset.relativePath,
            path.hasPrefix(ArchiveLayout.assetsDirectory + "/"),
            suppliedAsset.stableID == ArchiveAsset.stableID(for: path),
            paths.insert(path).inserted
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
        return path
    }

    private mutating func validateWorkspaceAsset(_ suppliedAsset: ProductionArchiveAsset, path: String) throws {
        guard let asset = workspaceAssets.removeValue(forKey: suppliedAsset.assetID),
            path == asset.relativePath,
            !path.hasPrefix(ProductionWorkspaceTransferAuthority.attachmentEvidenceAssetsDirectory + "/"),
            !path.hasPrefix(ProductionWorkspaceTransferAuthority.floorPlanAssetsDirectory + "/"),
            suppliedAsset.contentType == asset.metadata.contentType,
            suppliedAsset.bytes.count == asset.metadata.byteCount,
            CloudRecordAssetDescriptor.sha256(for: suppliedAsset.bytes) == asset.metadata.sha256
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
    }

    private mutating func validateEvidenceBinding(_ suppliedAsset: ProductionArchiveAsset, binding: AttachmentEvidenceBindingRecord, path: String) throws {
        guard let expected = evidenceBindings.removeValue(forKey: suppliedAsset.assetID),
            binding == expected,
            path == ProductionWorkspaceTransferAuthority.attachmentEvidenceAssetPath(for: binding.attachmentID),
            suppliedAsset.contentType == binding.assetMetadata.contentType,
            suppliedAsset.bytes.count == binding.assetMetadata.byteCount,
            CloudRecordAssetDescriptor.sha256(for: suppliedAsset.bytes) == binding.assetMetadata.sha256,
            AttachmentEvidenceBindingRecord.evidenceDigest(for: suppliedAsset.bytes) == binding.provenance.domainSeparatedSHA256
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
    }

    private mutating func validateFloorPlanBinding(_ suppliedAsset: ProductionArchiveAsset, binding: FloorPlanAssetBindingRecord, path: String) throws {
        guard let expected = floorPlanBindings.removeValue(forKey: suppliedAsset.assetID),
            binding == expected,
            path == ProductionWorkspaceTransferAuthority.floorPlanAssetPath(for: binding.floorID),
            suppliedAsset.contentType == binding.assetMetadata.contentType,
            suppliedAsset.bytes.count == binding.assetMetadata.byteCount,
            CloudRecordAssetDescriptor.sha256(for: suppliedAsset.bytes) == binding.assetMetadata.sha256
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
    }
}
