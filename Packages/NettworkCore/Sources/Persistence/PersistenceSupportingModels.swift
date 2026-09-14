import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

/// Durable deletion-identity evidence kept beside the authoritative local
/// mirror. This is intentionally a persistence DTO: CloudSync owns the
/// CloudKit-facing identity type and validates its deterministic record name.
public struct LocalCloudRecordNameIdentity: Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let recordName: String
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let systemFields: Data
    public let changeTag: String

    public init(
        namespace: PersistenceNamespace, recordName: String, resourceKey: ResourceKey,
        recordType: String, schemaVersion: Int, systemFields: Data, changeTag: String
    ) {
        self.namespace = namespace
        self.recordName = recordName
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.systemFields = systemFields
        self.changeTag = changeTag
    }
}

/// The production index must accommodate the complete supported CSV import
/// corpus. It does not evict entries: missing identity evidence makes a remote
/// deletion unverifiable and must fail closed instead.
public enum LocalCloudRecordNameIdentityIndexLimits {
    public static let minimumCapacity = 250_000
}

@Model
public final class LocalCloudRecordNameIdentityModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var recordName: String
    public var resourceKeyData: Data
    public var recordType: String
    public var schemaVersion: Int
    public var systemFields: Data
    public var changeTag: String

    public init(identity: LocalCloudRecordNameIdentity) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: identity.namespace)
        self.storageKey = PersistenceNamespaceKey.storageKey(
            namespace: identity.namespace,
            identity: "cloud-record-name-identity:\(identity.recordName)")
        self.namespaceKey = namespaceKey
        self.recordName = identity.recordName
        self.resourceKeyData = try PersistenceCoding.encode(identity.resourceKey)
        self.recordType = identity.recordType
        self.schemaVersion = identity.schemaVersion
        self.systemFields = identity.systemFields
        self.changeTag = identity.changeTag
    }
}

@Model
public final class OutboxMutationModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var operationID: String
    /// Retained only to make v1 rows inspectable. New operations never write
    /// these lossy fields and therefore cannot be replayed from them.
    public var kind: String?
    public var payload: Data?
    public var baseChangeTags: Data?
    public var lastError: String?
    /// The complete immutable envelope, including exact base snapshots/tags.
    public var operationData: Data = Data()
    public var stateRaw: String = OutboxState.poisoned.rawValue
    public var createdAt: Date
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastFailureData: Data?
    public var receiptData: Data?

    public init(operation: OutboxOperation) throws {
        self.storageKey = PersistenceNamespaceKey.storageKey(namespace: operation.namespace, identity: "outbox:\(operation.operationID.description)")
        self.namespaceKey = PersistenceNamespaceKey.value(for: operation.namespace)
        self.operationID = operation.operationID.description
        self.kind = nil
        self.payload = nil
        self.baseChangeTags = nil
        self.lastError = nil
        self.operationData = try PersistenceCoding.encode(operation)
        self.stateRaw = operation.state.rawValue
        self.createdAt = operation.createdAt
        self.attemptCount = operation.attemptCount
        self.nextRetryAt = operation.nextRetryAt
        self.lastFailureData = try operation.lastFailure.map { try PersistenceCoding.encode($0) }
        self.receiptData = try operation.receipt.map { try PersistenceCoding.encode($0) }
    }
}

@Model
public final class OperationReceiptModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var operationID: String
    public var receiptData: Data
    public var acceptedAt: Date

    public init(receipt: OperationReceipt, namespace: PersistenceNamespace, acceptedAt: Date) throws {
        self.storageKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "receipt:\(receipt.operationID.description)")
        self.namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.operationID = receipt.operationID.description
        self.receiptData = try PersistenceCoding.encode(receipt)
        self.acceptedAt = acceptedAt
    }
}

@Model
public final class LocalConflictModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var conflictData: Data
    public var detectedAt: Date
    public var isResolved: Bool

    public init(case reconciliationCase: ReconciliationCase) throws {
        self.storageKey = PersistenceNamespaceKey.storageKey(namespace: reconciliationCase.namespace, identity: "conflict:\(reconciliationCase.id.description)")
        self.namespaceKey = PersistenceNamespaceKey.value(for: reconciliationCase.namespace)
        self.conflictData = try PersistenceCoding.encode(reconciliationCase)
        self.detectedAt = reconciliationCase.detectedAt
        self.isResolved = false
    }
}

/// Exact, queryable resource membership for unresolved reconciliation cases.
/// The immutable reconciliation payload remains in `LocalConflictModel`.
@Model
public final class LocalConflictResourceIndexModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var conflictID: String
    public var resourceKeyDescription: String
    public var resourceKeyData: Data
    public var detectedAt: Date

    public init(case reconciliationCase: ReconciliationCase, resourceKey: ResourceKey) throws {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: reconciliationCase.namespace,
            identity: "conflict-resource:\(reconciliationCase.id.description):\(resourceKey.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: reconciliationCase.namespace)
        conflictID = reconciliationCase.id.description
        resourceKeyDescription = resourceKey.description
        resourceKeyData = try PersistenceCoding.encode(resourceKey)
        detectedAt = reconciliationCase.detectedAt
    }
}

@Model
public final class LocalSyncStateModel {
    @Attribute(.unique) public var namespaceKey: String
    public var stateData: Data
    public var updatedAt: Date

    public init(state: LocalSyncState) throws {
        self.namespaceKey = PersistenceNamespaceKey.value(for: state.namespace)
        self.stateData = try PersistenceCoding.encode(state)
        self.updatedAt = state.updatedAt
    }
}

@Model
public final class LocalWorkspaceVisibilityStateModel {
    @Attribute(.unique) public var namespaceKey: String
    public var stateData: Data
    public var updatedAt: Date

    public init(state: LocalWorkspaceVisibilityState) throws {
        self.namespaceKey = PersistenceNamespaceKey.value(for: state.namespace)
        self.stateData = try PersistenceCoding.encode(state)
        self.updatedAt = state.updatedAt
    }
}

@Model
public final class LocalAttachmentModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var attachmentID: String
    public var contentType: String
    public var relativePath: String
    public var byteCount: Int
    public var createdAt: Date

    public init(id: ObjectID, namespace: PersistenceNamespace, contentType: String, relativePath: String, byteCount: Int, createdAt: Date) {
        self.storageKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "attachment:\(id.description)")
        self.namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.attachmentID = id.description
        self.contentType = contentType
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

/// Durable intent marker for bytes downloaded before their mirror record and
/// sync cursor commit. It lets launch cleanup distinguish an interrupted
/// mirror download from an unrelated local attachment.
@Model
public final class LocalMirrorAssetStagingModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var attachmentID: String
    public var stagedAt: Date

    public init(id: ObjectID, namespace: PersistenceNamespace, stagedAt: Date = .now) {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "mirror-asset-staging:\(id.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        attachmentID = id.description
        self.stagedAt = stagedAt
    }
}

// MARK: V9 authoritative mirror-maintenance indexes

/// The V9 indexes are transport-derived facts, never a second domain model.
/// They make reference validation, staged-transfer lifecycle derivation, and
