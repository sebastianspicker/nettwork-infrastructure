import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

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
    /// Optional for the V4-to-V5 lightweight migration; nil is legacy live.
    public var visibilityData: Data?
    public var recordAssetMetadataData: Data?
    public var serverModifiedAt: Date
    public var verifiedAt: Date

    public init(record: LocalMirrorRecord) throws {
        let resourceKeyData = try PersistenceCoding.encode(record.resourceKey)
        let namespaceKey = PersistenceNamespaceKey.value(for: record.namespace)
        self.storageKey = PersistenceNamespaceKey.storageKey(namespace: record.namespace, identity: record.resourceKey.description)
        self.namespaceKey = namespaceKey
        self.resourceKeyData = resourceKeyData
        self.recordType = record.recordType
        self.schemaVersion = record.schemaVersion
        self.payload = record.payload
        self.systemFields = record.systemFields
        self.changeTag = record.changeTag
        self.isTombstone = record.isTombstone
        self.visibilityData = try PersistenceCoding.encode(record.visibility)
        self.recordAssetMetadataData = try record.recordAssetMetadata.map { try PersistenceCoding.encode($0) }
        self.serverModifiedAt = record.serverModifiedAt
        self.verifiedAt = record.verifiedAt
    }
}

/// Read-only, account-scoped inventory query materialization. It stores only
/// normalized domain search fields, never authoritative payloads or mutable
/// UI state. The source mirror remains the sole local authority.
public struct LocalInventorySearchRecord: Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let objectID: ObjectID
    public let resourceKey: ResourceKey
    public let kind: String
    public let title: String
    public let subtitle: String
    public let siteName: String?
    public let siteIDs: Set<ObjectID>
    public let searchTerms: [String]
    public let isPending: Bool

    public init(
        namespace: PersistenceNamespace, objectID: ObjectID, resourceKey: ResourceKey, kind: String,
        title: String, subtitle: String, siteName: String?, siteIDs: Set<ObjectID>, searchTerms: [String],
        isPending: Bool
    ) {
        self.namespace = namespace
        self.objectID = objectID
        self.resourceKey = resourceKey
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.siteName = siteName
        self.siteIDs = siteIDs
        self.searchTerms = searchTerms
        self.isPending = isPending
    }
}

@Model
public final class LocalInventorySearchIndexModel {
    /// A cable may legitimately include both bounded 16-level containment
    /// paths plus its own accepted 1 MiB authoritative payload fields. This
    /// bound accommodates the complete accepted text (including Unicode case
    /// expansion) without silently truncating searchable values.
    static let maximumSearchTextBytes = 128 * 1024 * 1024
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var objectIDValue: String
    public var resourceKeyData: Data
    public var kind: String
    public var title: String
    public var subtitle: String
    public var siteName: String?
    /// Delimited UUIDs let the typed SwiftData query match complete site IDs.
    public var siteMembershipTokens: String
    public var searchText: String
    public var searchTermsData: Data
    public var isPending: Bool

    public init(record: LocalInventorySearchRecord) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: record.namespace)
        self.storageKey = PersistenceNamespaceKey.storageKey(
            namespace: record.namespace,
            identity: "inventory-search:\(record.kind):\(record.objectID.description)")
        self.namespaceKey = namespaceKey
        self.objectIDValue = record.objectID.description
        self.resourceKeyData = try PersistenceCoding.encode(record.resourceKey)
        self.kind = record.kind
        self.title = record.title
        self.subtitle = record.subtitle
        self.siteName = record.siteName
        self.siteMembershipTokens = Self.siteMembershipTokens(record.siteIDs)
        let searchText = ([record.title, record.subtitle, record.siteName ?? ""] + record.searchTerms)
            .joined(separator: "\u{1F}").lowercased()
        guard searchText.lengthOfBytes(using: .utf8) <= Self.maximumSearchTextBytes else {
            throw PersistenceStoreError.inventorySearchTextTooLarge(record.objectID)
        }
        self.searchText = searchText
        self.searchTermsData = try PersistenceCoding.encode(record.searchTerms)
        self.isPending = record.isPending
    }

    static func siteMembershipToken(for siteID: ObjectID) -> String { "|\(siteID.description)|" }

    private static func siteMembershipTokens(_ siteIDs: Set<ObjectID>) -> String {
        siteIDs.sorted().map(siteMembershipToken(for:)).joined()
    }
}

/// A rebuildable normalized input to the inventory search materialization.
/// This is deliberately not authoritative: it contains only the verified
/// mirror identity plus the payload needed to re-normalize a bounded affected
/// closure without reading the entire workspace mirror.
@Model
public final class LocalInventoryProjectionNodeModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var resourceKeyData: Data
    public var recordType: String
    public var payload: Data?
    public var isTombstone: Bool

    public init(record: LocalMirrorRecord) throws {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: record.namespace,
            identity: "inventory-projection-node:\(record.resourceKey.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: record.namespace)
        resourceKeyData = try PersistenceCoding.encode(record.resourceKey)
        recordType = record.recordType
        payload = record.payload
        isTombstone = record.isTombstone
    }
}

/// A directed, exact dependency relation in the normalized inventory graph.
/// Each logical relationship is stored in both directions so reverse closure
/// lookup remains a typed, account-scoped SwiftData fetch.
@Model
public final class LocalInventoryProjectionEdgeModel {
    // The closure fetches by namespace + source and incident replacement by
    // namespace + target. Keep both columns indexed rather than allowing a
    // 2M-edge materialization to degrade into table scans.
    #Index<LocalInventoryProjectionEdgeModel>([\.namespaceKey, \.sourceKey], [\.namespaceKey, \.targetKey])
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var sourceKey: String
    public var targetKey: String
    public var kind: String

    public init(namespace: PersistenceNamespace, sourceKey: String, targetKey: String, kind: String) {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "inventory-projection-edge:\(kind):\(sourceKey):\(targetKey)")
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.sourceKey = sourceKey
        self.targetKey = targetKey
        self.kind = kind
    }
}

/// A namespace is queryable only when this marker describes a fully committed
/// V8 materialization. Counts make interrupted or incompatible derived state
/// fail closed into a transactional full rebuild rather than a false clean
/// incremental update.
@Model
public final class LocalInventoryProjectionStateModel {
    public static let currentSchemaVersion = 8
    @Attribute(.unique) public var namespaceKey: String
    public var schemaVersion: Int
    public var isComplete: Bool
    public var nodeCount: Int
    public var edgeCount: Int
    public var entryCount: Int
    public var updatedAt: Date

    public init(
        namespace: PersistenceNamespace, schemaVersion: Int = currentSchemaVersion, isComplete: Bool,
        nodeCount: Int = 0, edgeCount: Int = 0, entryCount: Int = 0, updatedAt: Date = .now
    ) {
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.schemaVersion = schemaVersion
        self.isComplete = isComplete
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
        self.entryCount = entryCount
        self.updatedAt = updatedAt
    }
}
