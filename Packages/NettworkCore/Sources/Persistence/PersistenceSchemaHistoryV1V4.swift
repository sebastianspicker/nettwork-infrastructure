import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

/// The shipped v1 SwiftData shape. Its outbox payload did not contain an
/// immutable execution envelope, so a v2 store retains those fields as
/// evidence instead of promoting them to an executable mutation.
public enum NettworkLocalSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [LocalRecordMirror.self, OutboxMutationModel.self]
    }

    @Model
    public final class LocalRecordMirror {
        @Attribute(.unique) public var storageKey: String
        public var namespaceKey: String
        public var resourceKeyData: Data
        public var recordType: String
        public var schemaVersion: Int
        public var payload: Data?
        public var systemFields: Data?
        public var changeTag: String?
        public var isTombstone: Bool
        public var serverModifiedAt: Date
        public var verifiedAt: Date

        public init(
            storageKey: String, namespaceKey: String, resourceKeyData: Data, recordType: String, schemaVersion: Int, payload: Data?, systemFields: Data?,
            changeTag: String?, isTombstone: Bool,
            serverModifiedAt: Date, verifiedAt: Date
        ) {
            self.storageKey = storageKey
            self.recordType = recordType
            self.schemaVersion = schemaVersion
            self.payload = payload
            self.systemFields = systemFields
            self.changeTag = changeTag
            self.isTombstone = isTombstone
            self.resourceKeyData = resourceKeyData
            self.namespaceKey = namespaceKey
            self.serverModifiedAt = serverModifiedAt
            self.verifiedAt = verifiedAt
        }
    }

    @Model
    public final class OutboxMutationModel {
        @Attribute(.unique) public var storageKey: String
        public var namespaceKey: String
        public var operationID: String
        public var kind: String
        public var payload: Data
        public var baseChangeTags: Data
        public var createdAt: Date
        public var attemptCount: Int
        public var lastError: String?

        public init(
            storageKey: String, namespaceKey: String, operationID: String, kind: String, payload: Data, baseChangeTags: Data, createdAt: Date,
            attemptCount: Int, lastError: String?
        ) {
            self.storageKey = storageKey
            self.namespaceKey = namespaceKey
            self.operationID = operationID
            self.kind = kind
            self.payload = payload
            self.baseChangeTags = baseChangeTags
            self.createdAt = createdAt
            self.attemptCount = attemptCount
            self.lastError = lastError
        }
    }
}

public enum NettworkLocalSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            NettworkLocalSchemaV4.LocalRecordMirror.self, OutboxMutationModel.self, OperationReceiptModel.self,
            LocalConflictModel.self, LocalSyncStateModel.self, LocalAttachmentModel.self,
            LocalQuarantineModel.self,
        ]
    }
}

public enum NettworkLocalSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(3, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            NettworkLocalSchemaV4.LocalRecordMirror.self, OutboxMutationModel.self, OperationReceiptModel.self,
            LocalConflictModel.self, LocalSyncStateModel.self, LocalAttachmentModel.self,
            LocalAttachmentEvidenceReservationModel.self, LocalAttachmentEvidenceModel.self,
            LocalQuarantineModel.self,
        ]
    }
}

public enum NettworkLocalSchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(4, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            LocalRecordMirror.self, LocalCloudRecordNameIdentityModel.self, OutboxMutationModel.self,
            OperationReceiptModel.self, LocalConflictModel.self, LocalSyncStateModel.self,
            LocalAttachmentModel.self, LocalAttachmentEvidenceReservationModel.self,
            LocalAttachmentEvidenceModel.self, LocalQuarantineModel.self,
        ]
    }

    /// V4 did not persist explicit visibility. Its rows migrate as nil, which
    /// V5 decodes as backward-compatible live visibility.
    @Model
    public final class LocalRecordMirror {
        @Attribute(.unique) public var storageKey: String
        public var namespaceKey: String
        public var resourceKeyData: Data
        public var recordType: String
        public var schemaVersion: Int
        public var payload: Data?
        public var systemFields: Data?
        public var changeTag: String?
        public var isTombstone: Bool
        public var serverModifiedAt: Date
        public var verifiedAt: Date

        public init(
            storageKey: String, namespaceKey: String, resourceKeyData: Data, recordType: String, schemaVersion: Int, payload: Data?, systemFields: Data?,
            changeTag: String?, isTombstone: Bool,
            serverModifiedAt: Date, verifiedAt: Date
        ) {
            self.storageKey = storageKey
            self.namespaceKey = namespaceKey
            self.resourceKeyData = resourceKeyData
            self.recordType = recordType
            self.schemaVersion = schemaVersion
            self.payload = payload
            self.systemFields = systemFields
            self.changeTag = changeTag
            self.isTombstone = isTombstone
            self.serverModifiedAt = serverModifiedAt
            self.verifiedAt = verifiedAt
        }
    }
}
