import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl

/// Keeps the compatibility and native restore paths on the same validation
/// and activation code without collecting file-backed archive payloads.
enum ProductionArchiveRestoreInput: Sendable {
    case memory(VerifiedArchive)
    case file(FileBackedVerifiedArchive)

    var manifest: ArchiveManifest {
        switch self {
        case .memory(let archive): archive.manifest
        case .file(let archive): archive.manifest
        }
    }

    var rootSHA256: String {
        switch self {
        case .memory(let archive): archive.rootSHA256
        case .file(let archive): archive.rootSHA256
        }
    }

    func readEntry(at path: String) throws -> Data {
        switch self {
        case .file(let archive): return try archive.readEntry(at: path)
        case .memory(let archive):
            switch path {
            case ArchiveLayout.recordsPath: return archive.recordsJSONL
            case ArchiveLayout.auditPath: return archive.auditJSONL
            default:
                guard let bytes = archive.assets[path] else { throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset }
                return bytes
            }
        }
    }

    func expectedReceipt(target: PersistenceNamespace, operationID: ObjectID) throws -> OperationReceipt {
        switch self {
        case .memory(let archive): try ArchiveRestoreActivationReceipt.expected(for: archive, target: target, operationID: operationID)
        case .file(let archive): try ArchiveRestoreActivationReceipt.expected(for: archive, target: target, operationID: operationID)
        }
    }

    func assetPayload(for asset: ArchiveAsset) throws -> ProductionRestoreAssetPayload {
        try Task.checkCancellation()
        let path = try ArchivePathPolicy.normalized(asset.relativePath)
        guard path == asset.relativePath, asset.stableID == ArchiveAsset.stableID(for: path),
            !asset.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset }
        let payload: ProductionRestoreAssetPayload
        switch self {
        case .memory:
            let bytes = try readEntry(at: path)
            payload = ProductionRestoreAssetPayload(bytes: bytes, storage: .inline(bytes))
        case .file(let archive):
            let descriptor = try archive.assetDescriptor(for: asset, fieldName: ProductionWorkspaceTransferAuthority.workspaceAssetFieldName)
            payload = ProductionRestoreAssetPayload(bytes: try descriptor.validatedBytes(), storage: descriptor.storage)
        }
        guard payload.bytes.count == asset.byteCount, CloudRecordAssetDescriptor.sha256(for: payload.bytes) == asset.sha256 else {
            throw ProductionWorkspaceTransferAuthorityError.invalidArchiveAsset
        }
        return payload
    }
}

/// Bytes are scoped to the validation of one asset; only storage is retained
/// by the resulting CloudRecordEnvelope for the upload batch.
struct ProductionRestoreAssetPayload: Sendable {
    let bytes: Data
    let storage: CloudRecordAssetDescriptor.Storage
}
