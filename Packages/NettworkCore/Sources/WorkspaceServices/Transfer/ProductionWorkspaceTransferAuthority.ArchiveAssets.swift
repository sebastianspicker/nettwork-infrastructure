import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func archiveAssetEnvelopes(
        from archive: ProductionArchiveRestoreInput, transfer: ValidatedWorkspaceTransfer, namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> [CloudRecordEnvelope] {
        var evidenceBindings = try attachmentBindingsByPath(from: transfer)
        var floorPlanBindings = try floorPlanBindingsByPath(from: transfer)
        let envelopes = try archive.manifest.assets.map { asset in
            try archiveAssetEnvelope(
                for: asset,
                assetPayload: try archive.assetPayload(for: asset),
                evidenceBindings: &evidenceBindings,
                floorPlanBindings: &floorPlanBindings,
                namespace: namespace,
                transferID: transferID
            )
        }
        guard evidenceBindings.isEmpty, floorPlanBindings.isEmpty else {
            throw ProductionWorkspaceTransferAuthorityError.missingArchiveAsset
        }
        return try sortedEnvelopes(envelopes)
    }

    private func attachmentBindingsByPath(from transfer: ValidatedWorkspaceTransfer) throws -> [String: AttachmentEvidenceBindingRecord] {
        try bindingsByPath(
            transfer.candidate.attachmentEvidenceBindings,
            path: { Self.attachmentEvidenceAssetPath(for: $0.attachmentID) }
        )
    }

    private func floorPlanBindingsByPath(from transfer: ValidatedWorkspaceTransfer) throws -> [String: FloorPlanAssetBindingRecord] {
        try bindingsByPath(
            transfer.candidate.floorPlanAssetBindings,
            path: { Self.floorPlanAssetPath(for: $0.floorID) }
        )
    }

    private func bindingsByPath<T>(
        _ bindings: [T],
        path: (T) -> String
    ) throws -> [String: T] {
        var result: [String: T] = [:]
        for binding in bindings {
            guard result.updateValue(binding, forKey: path(binding)) == nil else {
                throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
            }
        }
        return result
    }

    private func archiveAssetEnvelope(
        for asset: ArchiveAsset, assetPayload: ProductionRestoreAssetPayload, evidenceBindings: inout [String: AttachmentEvidenceBindingRecord],
        floorPlanBindings: inout [String: FloorPlanAssetBindingRecord], namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> CloudRecordEnvelope {
        let path = asset.relativePath
        if let binding = evidenceBindings.removeValue(forKey: path) {
            return try attachmentEvidenceEnvelope(binding, asset: asset, assetPayload: assetPayload, namespace: namespace, transferID: transferID)
        }
        if let binding = floorPlanBindings.removeValue(forKey: path) {
            return try floorPlanEnvelope(binding, asset: asset, assetPayload: assetPayload, namespace: namespace, transferID: transferID)
        }
        return try workspaceAssetEnvelope(asset, assetPayload: assetPayload, namespace: namespace, transferID: transferID)
    }

    private func attachmentEvidenceEnvelope(
        _ binding: AttachmentEvidenceBindingRecord, asset: ArchiveAsset, assetPayload: ProductionRestoreAssetPayload, namespace: PersistenceNamespace,
        transferID: ObjectID
    ) throws -> CloudRecordEnvelope {
        guard asset.id == binding.attachmentID,
            asset.contentType == binding.assetMetadata.contentType,
            asset.byteCount == binding.assetMetadata.byteCount,
            asset.sha256 == binding.assetMetadata.sha256,
            AttachmentEvidenceBindingRecord.evidenceDigest(for: assetPayload.bytes) == binding.provenance.domainSeparatedSHA256
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
        return try assetBindingEnvelope(
            resourceKey: binding.resourceKey,
            recordType: CloudRecordNaming.attachmentEvidenceBindingRecordType,
            payload: CloudDeterministicCoding.encode(binding),
            metadata: binding.assetMetadata,
            storage: assetPayload.storage,
            namespace: namespace,
            transferID: transferID
        )
    }

    private func floorPlanEnvelope(
        _ binding: FloorPlanAssetBindingRecord, asset: ArchiveAsset, assetPayload: ProductionRestoreAssetPayload, namespace: PersistenceNamespace,
        transferID: ObjectID
    ) throws -> CloudRecordEnvelope {
        guard asset.id == binding.assetMetadata.id,
            asset.contentType == binding.assetMetadata.contentType,
            asset.byteCount == binding.assetMetadata.byteCount,
            asset.sha256 == binding.assetMetadata.sha256
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
        return try assetBindingEnvelope(
            resourceKey: binding.resourceKey,
            recordType: CloudRecordNaming.floorPlanAssetBindingRecordType,
            payload: CloudDeterministicCoding.encode(binding),
            metadata: binding.assetMetadata,
            storage: assetPayload.storage,
            namespace: namespace,
            transferID: transferID
        )
    }

    private func assetBindingEnvelope(
        resourceKey: ResourceKey, recordType: String, payload: Data, metadata: CloudRecordAssetMetadata, storage: CloudRecordAssetDescriptor.Storage,
        namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> CloudRecordEnvelope {
        let descriptor = try CloudRecordAssetDescriptor(
            id: metadata.id,
            fieldName: metadata.fieldName,
            sha256: metadata.sha256,
            contentType: metadata.contentType,
            byteCount: metadata.byteCount,
            storage: storage
        )
        guard descriptor.metadata == metadata else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
        return CloudRecordEnvelope(
            resourceKey: resourceKey,
            workspaceID: namespace.workspaceID,
            recordType: recordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: payload,
            recordAsset: descriptor,
            visibility: .staged(transferID: transferID),
            systemFields: Data(),
            changeTag: ""
        )
    }

    private func workspaceAssetEnvelope(
        _ asset: ArchiveAsset, assetPayload: ProductionRestoreAssetPayload, namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> CloudRecordEnvelope {
        let path = asset.relativePath
        guard !path.hasPrefix(Self.attachmentEvidenceAssetsDirectory + "/"),
            !path.hasPrefix(Self.floorPlanAssetsDirectory + "/")
        else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
        let descriptor = try CloudRecordAssetDescriptor(
            id: asset.id,
            fieldName: Self.workspaceAssetFieldName,
            sha256: asset.sha256,
            contentType: asset.contentType,
            byteCount: asset.byteCount,
            storage: assetPayload.storage
        )
        let record = try CloudWorkspaceAssetRecord(assetID: asset.id, relativePath: path, metadata: descriptor.metadata)
        return CloudRecordEnvelope(
            resourceKey: record.resourceKey,
            workspaceID: namespace.workspaceID,
            recordType: CloudRecordNaming.workspaceAssetRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: try CloudDeterministicCoding.encode(record),
            recordAsset: descriptor,
            visibility: .staged(transferID: transferID),
            systemFields: Data(),
            changeTag: ""
        )
    }

    static func attachmentEvidenceAssetPath(for attachmentID: ObjectID) -> String {
        attachmentEvidenceAssetsDirectory + "/" + attachmentID.description + ".jpg"
    }

    static func floorPlanAssetPath(for floorID: ObjectID) -> String {
        floorPlanAssetsDirectory + "/" + floorID.description + ".jpg"
    }
}
