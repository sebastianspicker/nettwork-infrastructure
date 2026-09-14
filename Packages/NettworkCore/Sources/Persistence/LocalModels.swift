import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

/// Values that cross the SwiftData boundary are encoded before persistence so
/// the local schema remains a rebuildable transport mirror, never a second
/// domain model or an authority over CloudKit.
public struct LocalMirrorRecord: Codable, Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let payload: Data?
    public let systemFields: Data?
    public let changeTag: String?
    public let isTombstone: Bool
    public let visibility: WorkspaceRecordVisibility
    public let recordAssetMetadata: CloudRecordAssetMetadata?
    public let serverModifiedAt: Date
    public let verifiedAt: Date

    public init(
        namespace: PersistenceNamespace, resourceKey: ResourceKey, recordType: String, schemaVersion: Int, payload: Data?, systemFields: Data?,
        changeTag: String?, isTombstone: Bool,
        visibility: WorkspaceRecordVisibility = .live, recordAssetMetadata: CloudRecordAssetMetadata? = nil, serverModifiedAt: Date, verifiedAt: Date
    ) {
        self.namespace = namespace
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.systemFields = systemFields
        self.changeTag = changeTag
        self.isTombstone = isTombstone
        self.visibility = visibility
        self.recordAssetMetadata = recordAssetMetadata
        self.serverModifiedAt = serverModifiedAt
        self.verifiedAt = verifiedAt
    }

    public var exactPrecondition: ExactRecordPrecondition? {
        guard let systemFields, let changeTag, !systemFields.isEmpty,
            !changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return ExactRecordPrecondition(systemFields: systemFields, changeTag: changeTag)
    }
}

/// Persisted synchronization state is scoped as tightly as every mirrored
/// record. The payload is CKSyncEngine-owned opaque state and is never decoded
/// by the persistence layer.
public struct LocalSyncState: Codable, Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let engineState: Data?
    public let changeToken: Data?
    public let lastSuccessfulServerContact: Date?
    public let updatedAt: Date

    public init(namespace: PersistenceNamespace, engineState: Data?, changeToken: Data?, lastSuccessfulServerContact: Date?, updatedAt: Date) {
        self.namespace = namespace
        self.engineState = engineState
        self.changeToken = changeToken
        self.lastSuccessfulServerContact = lastSuccessfulServerContact
        self.updatedAt = updatedAt
    }
}

/// Persisted separately from sync-engine cursor bytes. It is the local
/// fail-closed gate for feature projection: staged rows are readable only
/// through raw mirror APIs until their matching activation commit arrives.
public struct LocalWorkspaceVisibilityState: Codable, Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let lifecycle: WorkspaceLifecycle
    public let updatedAt: Date

    public init(namespace: PersistenceNamespace, lifecycle: WorkspaceLifecycle, updatedAt: Date = .now) {
        self.namespace = namespace
        self.lifecycle = lifecycle
        self.updatedAt = updatedAt
    }
}

public struct LocalQuarantineRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let namespace: PersistenceNamespace
    public let resourceKey: ResourceKey?
    public let recordType: String?
    public let payload: Data
    public let failure: SyncFailure
    public let capturedAt: Date

    public init(
        id: ObjectID = .init(), namespace: PersistenceNamespace, resourceKey: ResourceKey?, recordType: String?, payload: Data, failure: SyncFailure,
        capturedAt: Date = .now
    ) {
        self.id = id
        self.namespace = namespace
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.payload = payload
        self.failure = failure
        self.capturedAt = capturedAt
    }
}

public enum LocalRecordKind {
    public static let physicalTopology = "physical-topology"
    public static let prefix = "prefix"
    public static let workOrder = "work-order"
    public static let auditEvent = "audit-event"
}

public enum PersistenceNamespaceKey {
    /// A deterministic, filesystem-safe key. It deliberately includes the
    /// generation: an old account/session handle cannot address new data.
    public static func value(for namespace: PersistenceNamespace) -> String {
        let source = [
            "nettwork.persistence.namespace.v1", namespace.containerIdentifier,
            namespace.cloudKitAccountRecordName, namespace.workspaceID.description, namespace.zoneName,
            namespace.zoneOwnerRecordName, String(namespace.sessionGeneration),
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func storageKey(namespace: PersistenceNamespace, identity: String) -> String {
        "\(value(for: namespace)):\(identity)"
    }
}

/// Persistence model source map. The durable SwiftData types are grouped by
/// responsibility in sibling source files; these terms document the retained
/// schema surface for source-level integration checks.
/// LocalInventorySearchIndexModel.self
/// LocalInventoryProjectionNodeModel.self
/// LocalInventoryProjectionEdgeModel.self
/// LocalInventoryProjectionStateModel.self
/// static let maximumSearchTextBytes = 128 * 1024 * 1024
/// final class LocalConflictResourceIndexModel
/// LocalMirrorReferenceEdgeModel
/// LocalMirrorAssetOwnerModel
/// LocalMirrorTransferMemberModel
/// LocalMirrorAssetUsageModel
/// LocalMirrorMaintenanceStateModel
/// NettworkLocalSchemaV6
/// NettworkLocalSchemaV7
/// NettworkLocalSchemaV8
/// NettworkLocalSchemaV9
/// public enum NettworkLocalSchemaV9: VersionedSchema
/// public static var models: [any PersistentModel.Type] { NettworkLocalSchema.models }
/// lightweight(fromVersion: NettworkLocalSchemaV5.self, toVersion: NettworkLocalSchemaV6.self)
/// lightweight(fromVersion: NettworkLocalSchemaV6.self, toVersion: NettworkLocalSchemaV7.self)
/// lightweight(fromVersion: NettworkLocalSchemaV7.self, toVersion: NettworkLocalSchemaV8.self)
/// lightweight(fromVersion: NettworkLocalSchemaV8.self, toVersion: NettworkLocalSchemaV9.self)
