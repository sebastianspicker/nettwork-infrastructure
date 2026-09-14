import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func mirrorTransferAssetUsage(transferID: ObjectID, in namespace: PersistenceNamespace) throws -> (assetCount: Int, byteCount: Int)? {
        try validateActiveLease(for: namespace)
        guard let usage = try mirrorTransferAssetUsageModel(transferID: transferID, namespace: namespace) else { return nil }
        return (usage.assetCount, usage.byteCount)
    }

    func mirrorReferenceEdgeModels(namespaceKey: String, sourceKey: String) throws -> [LocalMirrorReferenceEdgeModel] {
        let descriptor = FetchDescriptor<LocalMirrorReferenceEdgeModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.sourceKey == sourceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorReferenceEdgeModels(namespaceKey: String) throws -> [LocalMirrorReferenceEdgeModel] {
        let descriptor = FetchDescriptor<LocalMirrorReferenceEdgeModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorReferenceEdgeModels(namespaceKey: String, targetKey: String, fetchLimit: Int) throws -> [LocalMirrorReferenceEdgeModel] {
        var descriptor = FetchDescriptor<LocalMirrorReferenceEdgeModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.targetKey == targetKey })
        descriptor.fetchLimit = fetchLimit
        return try modelContext.fetch(descriptor)
    }

    func mirrorAssetOwnerModel(assetID: ObjectID, namespace: PersistenceNamespace) throws -> LocalMirrorAssetOwnerModel? {
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "mirror-asset-owner:\(assetID.description)")
        let descriptor = FetchDescriptor<LocalMirrorAssetOwnerModel>(predicate: #Predicate { $0.storageKey == key })
        return try modelContext.fetch(descriptor).first
    }

    func mirrorAssetOwnerModels(namespaceKey: String, transferID: ObjectID) throws -> [LocalMirrorAssetOwnerModel] {
        let transfer = transferID.description
        let descriptor = FetchDescriptor<LocalMirrorAssetOwnerModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.transferID == transfer })
        return try modelContext.fetch(descriptor)
    }

    func mirrorAssetOwnerModels(namespaceKey: String) throws -> [LocalMirrorAssetOwnerModel] {
        let descriptor = FetchDescriptor<LocalMirrorAssetOwnerModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorAssetOwnerRepairPage(namespaceKey: String, afterStorageKey: String?, fetchLimit: Int) throws -> [LocalMirrorAssetOwnerModel] {
        var descriptor: FetchDescriptor<LocalMirrorAssetOwnerModel>
        if let afterStorageKey {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.storageKey > afterStorageKey })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        }
        descriptor.sortBy = [SortDescriptor(\.storageKey)]
        descriptor.fetchLimit = fetchLimit
        return try modelContext.fetch(descriptor)
    }

    func mirrorTransferMemberStorageKey(transferID: ObjectID, resourceKey: ResourceKey, namespace: PersistenceNamespace) -> String {
        PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "mirror-transfer-member:\(transferID.description):\(resourceKey.description)")
    }

    func mirrorTransferMemberModel(matching storageKey: String) throws -> LocalMirrorTransferMemberModel? {
        let descriptor = FetchDescriptor<LocalMirrorTransferMemberModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func mirrorTransferMemberModels(namespaceKey: String, transferID: ObjectID, fetchLimit: Int) throws -> [LocalMirrorTransferMemberModel] {
        let transfer = transferID.description
        var descriptor = FetchDescriptor<LocalMirrorTransferMemberModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.transferID == transfer })
        descriptor.fetchLimit = fetchLimit
        return try modelContext.fetch(descriptor)
    }

    func mirrorTransferMemberModels(namespaceKey: String) throws -> [LocalMirrorTransferMemberModel] {
        let descriptor = FetchDescriptor<LocalMirrorTransferMemberModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorAssetUsageModel(matching namespaceKey: String) throws -> LocalMirrorAssetUsageModel? {
        let descriptor = FetchDescriptor<LocalMirrorAssetUsageModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor).first
    }

    func mirrorTransferAssetUsageModel(transferID: ObjectID, namespace: PersistenceNamespace) throws -> LocalMirrorTransferAssetUsageModel? {
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "mirror-transfer-asset-usage:\(transferID.description)")
        let descriptor = FetchDescriptor<LocalMirrorTransferAssetUsageModel>(predicate: #Predicate { $0.storageKey == key })
        return try modelContext.fetch(descriptor).first
    }

    func mirrorTransferAssetUsageModels(namespaceKey: String) throws -> [LocalMirrorTransferAssetUsageModel] {
        let descriptor = FetchDescriptor<LocalMirrorTransferAssetUsageModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorMaintenanceStateModel(matching namespaceKey: String) throws -> LocalMirrorMaintenanceStateModel? {
        let descriptor = FetchDescriptor<LocalMirrorMaintenanceStateModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor).first
    }

    func workspaceVisibilityStateModel(
        matching namespaceKey: String
    ) throws -> LocalWorkspaceVisibilityStateModel? {
        let descriptor = FetchDescriptor<LocalWorkspaceVisibilityStateModel>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor).first
    }

    func outboxModel(matching storageKey: String) throws -> OutboxMutationModel? {
        let descriptor = FetchDescriptor<OutboxMutationModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func outboxModels(namespaceKey: String) throws -> [OutboxMutationModel] {
        let descriptor = FetchDescriptor<OutboxMutationModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func receiptModel(matching storageKey: String) throws -> OperationReceiptModel? {
        let descriptor = FetchDescriptor<OperationReceiptModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func receiptModels(namespaceKey: String) throws -> [OperationReceiptModel] {
        let descriptor = FetchDescriptor<OperationReceiptModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func conflictModel(matching storageKey: String) throws -> LocalConflictModel? {
        let descriptor = FetchDescriptor<LocalConflictModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func conflictModels(namespaceKey: String) throws -> [LocalConflictModel] {
        let descriptor = FetchDescriptor<LocalConflictModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func conflictResourceIndexModels(namespaceKey: String) throws -> [LocalConflictResourceIndexModel] {
        let descriptor = FetchDescriptor<LocalConflictResourceIndexModel>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func attachmentModel(matching storageKey: String) throws -> LocalAttachmentModel? {
        let descriptor = FetchDescriptor<LocalAttachmentModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func mirrorAssetStagingModel(
        matching storageKey: String
    ) throws -> LocalMirrorAssetStagingModel? {
        let descriptor = FetchDescriptor<LocalMirrorAssetStagingModel>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        return try modelContext.fetch(descriptor).first
    }

    func mirrorAssetStagingModels(
        namespaceKey: String
    ) throws -> [LocalMirrorAssetStagingModel] {
        let descriptor = FetchDescriptor<LocalMirrorAssetStagingModel>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey }
        )
        return try modelContext.fetch(descriptor)
    }

    func attachmentEvidenceReservationStorageKey(
        attachmentID: ObjectID,
        namespace: PersistenceNamespace
    ) -> String {
        PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "attachment-reservation:\(attachmentID.description)"
        )
    }

    func attachmentEvidenceStorageKey(
        attachmentID: ObjectID,
        namespace: PersistenceNamespace
    ) -> String {
        PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "attachment-evidence:\(attachmentID.description)"
        )
    }

    func attachmentEvidenceReservationModel(
        matching storageKey: String
    ) throws -> LocalAttachmentEvidenceReservationModel? {
        let descriptor = FetchDescriptor<LocalAttachmentEvidenceReservationModel>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        return try modelContext.fetch(descriptor).first
    }

    func attachmentEvidenceReservationModels(
        namespaceKey: String
    ) throws -> [LocalAttachmentEvidenceReservationModel] {
        let descriptor = FetchDescriptor<LocalAttachmentEvidenceReservationModel>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey }
        )
        return try modelContext.fetch(descriptor)
    }

    func attachmentEvidenceModel(
        matching storageKey: String
    ) throws -> LocalAttachmentEvidenceModel? {
        let descriptor = FetchDescriptor<LocalAttachmentEvidenceModel>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        return try modelContext.fetch(descriptor).first
    }

    func attachmentEvidenceModels(namespaceKey: String) throws -> [LocalAttachmentEvidenceModel] {
        let descriptor = FetchDescriptor<LocalAttachmentEvidenceModel>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey }
        )
        return try modelContext.fetch(descriptor)
    }

    func decodeAttachmentEvidenceReservation(
        _ model: LocalAttachmentEvidenceReservationModel,
        namespace: PersistenceNamespace
    ) throws -> AttachmentEvidenceReservationMetadata {
        let reservation = try PersistenceCoding.decode(
            AttachmentEvidenceReservationMetadata.self,
            from: model.reservationData
        )
        guard reservation.namespace == namespace,
            reservation.id.description == model.reservationID,
            reservation.attachmentID.description == model.attachmentID,
            reservation.workOrderID.description == model.workOrderID,
            reservation.expiresAt == model.expiresAt
        else {
            throw PersistenceStoreError.malformedStoredValue("attachment evidence reservation")
        }
        return reservation
    }

    func decodeAttachmentEvidence(
        _ model: LocalAttachmentEvidenceModel,
        namespace: PersistenceNamespace
    ) throws -> AttachmentEvidenceMetadata {
        let evidence = try PersistenceCoding.decode(AttachmentEvidenceMetadata.self, from: model.evidenceData)
        guard evidence.namespace == namespace,
            evidence.attachmentID.description == model.attachmentID,
            evidence.workOrderID.description == model.workOrderID,
            evidence.boundAt == model.boundAt
        else {
            throw PersistenceStoreError.malformedStoredValue("attachment evidence")
        }
        return evidence
    }

    func removeExpiredAttachmentEvidenceReservations(
        in namespace: PersistenceNamespace,
        at now: Date
    ) throws {
        for model in try attachmentEvidenceReservationModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
        where model.expiresAt <= now {
            modelContext.delete(model)
        }
    }

    func quarantineModels(namespaceKey: String) throws -> [LocalQuarantineModel] {
        let descriptor = FetchDescriptor<LocalQuarantineModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func syncStateModels(namespaceKey: String) throws -> [LocalSyncStateModel] {
        let descriptor = FetchDescriptor<LocalSyncStateModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func syncStateModel(matching namespaceKey: String) throws -> LocalSyncStateModel? {
        let descriptor = FetchDescriptor<LocalSyncStateModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor).first
    }
}
