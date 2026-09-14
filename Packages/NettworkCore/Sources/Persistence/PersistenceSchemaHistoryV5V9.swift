import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

public enum NettworkLocalSchemaV5: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(5, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            LocalRecordMirror.self, LocalCloudRecordNameIdentityModel.self, OutboxMutationModel.self,
            OperationReceiptModel.self, LocalConflictModel.self, LocalSyncStateModel.self,
            LocalWorkspaceVisibilityStateModel.self, LocalAttachmentModel.self,
            LocalMirrorAssetStagingModel.self, LocalAttachmentEvidenceReservationModel.self,
            LocalAttachmentEvidenceModel.self, LocalQuarantineModel.self,
        ]
    }
}

public enum NettworkLocalSchemaV6: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(6, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            LocalRecordMirror.self, LocalInventorySearchIndexModel.self, LocalCloudRecordNameIdentityModel.self,
            OutboxMutationModel.self, OperationReceiptModel.self, LocalConflictModel.self,
            LocalSyncStateModel.self, LocalWorkspaceVisibilityStateModel.self, LocalAttachmentModel.self,
            LocalMirrorAssetStagingModel.self, LocalAttachmentEvidenceReservationModel.self,
            LocalAttachmentEvidenceModel.self, LocalQuarantineModel.self,
        ]
    }
}

public enum NettworkLocalSchemaV7: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(7, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            LocalRecordMirror.self, LocalInventorySearchIndexModel.self, LocalCloudRecordNameIdentityModel.self,
            OutboxMutationModel.self, OperationReceiptModel.self, LocalConflictModel.self,
            LocalConflictResourceIndexModel.self, LocalSyncStateModel.self,
            LocalWorkspaceVisibilityStateModel.self, LocalAttachmentModel.self,
            LocalMirrorAssetStagingModel.self, LocalAttachmentEvidenceReservationModel.self,
            LocalAttachmentEvidenceModel.self, LocalQuarantineModel.self,
        ]
    }
}

public enum NettworkLocalSchemaV8: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(8, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            LocalRecordMirror.self, LocalInventorySearchIndexModel.self, LocalInventoryProjectionNodeModel.self,
            LocalInventoryProjectionEdgeModel.self, LocalInventoryProjectionStateModel.self,
            LocalCloudRecordNameIdentityModel.self, OutboxMutationModel.self, OperationReceiptModel.self,
            LocalConflictModel.self, LocalConflictResourceIndexModel.self, LocalSyncStateModel.self,
            LocalWorkspaceVisibilityStateModel.self, LocalAttachmentModel.self,
            LocalMirrorAssetStagingModel.self, LocalAttachmentEvidenceReservationModel.self,
            LocalAttachmentEvidenceModel.self, LocalQuarantineModel.self,
        ]
    }
}

/// V9 adds only rebuildable mirror-maintenance facts. V1–V8 remain immutable
/// historical schemas so existing containers follow one additive migration.
public enum NettworkLocalSchemaV9: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(9, 0, 0) }
    public static var models: [any PersistentModel.Type] { NettworkLocalSchema.models }
}

/// Actual SwiftData schema history used by production containers. V2 preserves
/// v1's opaque outbox columns but gives new mutation columns safe defaults; a
/// row without a complete envelope remains reconciliation evidence only.
public enum NettworkLocalSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            NettworkLocalSchemaV1.self, NettworkLocalSchemaV2.self, NettworkLocalSchemaV3.self,
            NettworkLocalSchemaV4.self, NettworkLocalSchemaV5.self, NettworkLocalSchemaV6.self,
            NettworkLocalSchemaV7.self, NettworkLocalSchemaV8.self, NettworkLocalSchemaV9.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: NettworkLocalSchemaV1.self, toVersion: NettworkLocalSchemaV2.self),
            .lightweight(fromVersion: NettworkLocalSchemaV2.self, toVersion: NettworkLocalSchemaV3.self),
            .lightweight(fromVersion: NettworkLocalSchemaV3.self, toVersion: NettworkLocalSchemaV4.self),
            .lightweight(fromVersion: NettworkLocalSchemaV4.self, toVersion: NettworkLocalSchemaV5.self),
            .lightweight(fromVersion: NettworkLocalSchemaV5.self, toVersion: NettworkLocalSchemaV6.self),
            .lightweight(fromVersion: NettworkLocalSchemaV6.self, toVersion: NettworkLocalSchemaV7.self),
            .lightweight(fromVersion: NettworkLocalSchemaV7.self, toVersion: NettworkLocalSchemaV8.self),
            .lightweight(fromVersion: NettworkLocalSchemaV8.self, toVersion: NettworkLocalSchemaV9.self),
        ]
    }
}
