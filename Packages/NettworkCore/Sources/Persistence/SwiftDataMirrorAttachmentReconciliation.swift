import Foundation
import NetworkModel
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    func reconcileVerifiedMirrorAttachment(
        _ id: ObjectID, namespace: PersistenceNamespace
    ) async throws -> Int {
        let markerKey = mirrorAssetStagingStorageKey(id, namespace: namespace)
        guard try !mirrorAttachmentIsProtected(id, namespace: namespace) else {
            try removeMirrorAssetStagingMarker(markerKey, namespace: namespace)
            return 0
        }
        let attachmentKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "attachment:\(id.description)")
        guard let attachment = try attachmentModel(matching: attachmentKey) else {
            try removeMirrorAssetStagingMarker(markerKey, namespace: namespace)
            return 0
        }
        try await attachmentFiles.remove(relativePath: attachment.relativePath, id: id)
        try removeMirrorAttachmentModels(attachmentKey: attachmentKey, markerKey: markerKey, namespace: namespace)
        return 1
    }

    private func mirrorAttachmentIsProtected(
        _ id: ObjectID, namespace: PersistenceNamespace
    ) throws -> Bool {
        if try mirrorAssetOwnerModel(assetID: id, namespace: namespace) != nil { return true }
        let reservationKey = attachmentEvidenceReservationStorageKey(attachmentID: id, namespace: namespace)
        if try attachmentEvidenceReservationModel(matching: reservationKey) != nil { return true }
        let evidenceKey = attachmentEvidenceStorageKey(attachmentID: id, namespace: namespace)
        return try attachmentEvidenceModel(matching: evidenceKey) != nil
    }

    private func mirrorAssetStagingStorageKey(_ id: ObjectID, namespace: PersistenceNamespace) -> String {
        PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "mirror-asset-staging:\(id.description)")
    }

    private func removeMirrorAssetStagingMarker(
        _ markerKey: String, namespace: PersistenceNamespace
    ) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            if let marker = try mirrorAssetStagingModel(matching: markerKey) {
                modelContext.delete(marker)
            }
        }
    }

    private func removeMirrorAttachmentModels(
        attachmentKey: String, markerKey: String,
        namespace: PersistenceNamespace
    ) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            if let attachment = try attachmentModel(matching: attachmentKey) {
                modelContext.delete(attachment)
            }
            if let marker = try mirrorAssetStagingModel(matching: markerKey) {
                modelContext.delete(marker)
            }
        }
    }
}
