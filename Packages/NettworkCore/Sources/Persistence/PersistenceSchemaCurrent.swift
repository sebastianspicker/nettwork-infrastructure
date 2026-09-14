import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

public enum NettworkLocalSchema {
    public static let version = 9
    /// Policy for interpreting retained v1 outbox evidence after the SwiftData
    /// migration below. A legacy payload is never guessed into a replayable
    /// operation without its exact envelope and base state.
    public static let legacyOutboxMigrationPolicy = NettworkPersistenceMigrationPlan.v1ToV2
    public static let models: [any PersistentModel.Type] = [
        LocalRecordMirror.self,
        LocalInventorySearchIndexModel.self, LocalInventoryProjectionNodeModel.self,
        LocalInventoryProjectionEdgeModel.self, LocalInventoryProjectionStateModel.self,
        LocalCloudRecordNameIdentityModel.self, OutboxMutationModel.self, OperationReceiptModel.self,
        LocalConflictModel.self, LocalConflictResourceIndexModel.self, LocalSyncStateModel.self,
        LocalWorkspaceVisibilityStateModel.self, LocalAttachmentModel.self, LocalMirrorAssetStagingModel.self,
        LocalMirrorReferenceEdgeModel.self, LocalMirrorAssetOwnerModel.self,
        LocalMirrorTransferMemberModel.self, LocalMirrorAssetUsageModel.self,
        LocalMirrorTransferAssetUsageModel.self, LocalMirrorMaintenanceStateModel.self,
        LocalAttachmentEvidenceReservationModel.self, LocalAttachmentEvidenceModel.self,
        LocalQuarantineModel.self,
    ]
    public static let schema = Schema(models)
}
