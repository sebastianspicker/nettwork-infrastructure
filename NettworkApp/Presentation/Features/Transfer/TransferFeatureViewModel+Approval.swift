import ImportExport

@MainActor
extension TransferFeatureViewModel {
    var archiveRestoreApprovalPresentation: ArchiveRestoreApprovalPresentation? {
        guard case let .readyToRestore(preview) = archiveState,
            let authorization = stagedArchiveAuthorization
        else { return nil }
        let manifest = preview.archive.manifest
        guard let recordCount = try? ArchiveManifestRecordCounts.total(manifest.recordCounts) else {
            return nil
        }
        return ArchiveRestoreApprovalPresentation(
            sourceWorkspaceID: manifest.provenance.workspaceID,
            sourceZone: manifest.provenance.zoneName,
            sourceZoneOwner: manifest.provenance.zoneOwnerRecordName,
            targetWorkspaceID: authorization.account.namespace.workspaceID,
            targetZone: authorization.account.namespace.zoneName,
            targetZoneOwner: authorization.account.namespace.zoneOwnerRecordName,
            operationID: authorization.operationID,
            createdAt: manifest.createdAt,
            recordCount: recordCount,
            assetCount: manifest.assets.count,
            assetByteCount: manifest.assets.reduce(0) { $0 + $1.byteCount },
            auditRecordCount: manifest.auditRecordCount,
            auditHeadSHA256: manifest.auditHeadSHA256,
            rootSHA256: manifest.rootSHA256,
            compatibility:
                "\(manifest.compatibility.archiveFormat) reader "
                + "\(manifest.compatibility.minimumReaderVersion)–"
                + "\(manifest.compatibility.maximumReaderVersion)"
        )
    }
}
