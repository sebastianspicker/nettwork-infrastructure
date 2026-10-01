import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum SwiftDataCloudRecordNameIdentityIndexError: Error, Hashable, Sendable {
    case namespaceMismatch
    case invalidMaximumEntries(Int)
    case capacityConfigurationMismatch(expected: Int, received: Int)
}

/// Production CloudKit deletion identity index. Its storage is protected by
/// the Persistence namespace lease already held by the mirror bridge, so a
/// callback from an invalidated account or workspace generation cannot read,
/// write, reconcile, or purge another namespace's evidence.
public actor SwiftDataCloudRecordNameIdentityIndex: CloudRecordNameIdentityIndex {
    public static let defaultMaximumEntries = 300_000

    private let persistence: SwiftDataPersistenceStore
    private let namespace: PersistenceNamespace
    private let maximumEntries: Int

    public init(
        persistence: SwiftDataPersistenceStore,
        namespace: PersistenceNamespace,
        maximumEntries: Int = SwiftDataCloudRecordNameIdentityIndex.defaultMaximumEntries
    ) throws {
        guard maximumEntries >= LocalCloudRecordNameIdentityIndexLimits.minimumCapacity else {
            throw SwiftDataCloudRecordNameIdentityIndexError.invalidMaximumEntries(maximumEntries)
        }
        self.persistence = persistence
        self.namespace = namespace
        self.maximumEntries = maximumEntries
    }

    public func identity(for recordName: String, in requestedNamespace: PersistenceNamespace) async throws -> CloudRecordNameIdentity? {
        try requireNamespace(requestedNamespace)

        // A verified local mirror is more current than an index row retained
        // across a previous launch or mirror rebuild. Reconcile this one name
        // first, then use the durable row when no mirrored evidence remains.
        if let mirroredIdentity = try await mirroredIdentity(for: recordName) {
            try await persistence.storeCloudRecordNameIdentity(mirroredIdentity, in: namespace, maximumEntries: maximumEntries)
            return try cloudIdentity(from: mirroredIdentity)
        }

        guard let identity = try await persistence.cloudRecordNameIdentity(for: recordName, in: namespace) else {
            return nil
        }
        return try cloudIdentity(from: identity)
    }

    public func store(_ identity: CloudRecordNameIdentity, in requestedNamespace: PersistenceNamespace, maximumEntries requestedMaximumEntries: Int)
        async throws
    {
        try requireNamespace(requestedNamespace)
        guard requestedMaximumEntries == maximumEntries else {
            throw SwiftDataCloudRecordNameIdentityIndexError.capacityConfigurationMismatch(expected: maximumEntries, received: requestedMaximumEntries)
        }
        try validateIdentity(
            recordName: identity.recordName, resourceKey: identity.resourceKey, recordType: identity.recordType,
            schemaVersion: identity.schemaVersion, systemFields: identity.systemFields, changeTag: identity.changeTag)

        try await persistence.storeCloudRecordNameIdentity(
            localIdentity(from: identity),
            in: namespace,
            maximumEntries: maximumEntries
        )
    }

    /// Rebuilds durable entries from the verified mirror in one atomic store
    /// transaction. Rows with incomplete precondition evidence are skipped;
    /// they cannot safely identify a CloudKit deletion.
    public func reconcileFromMirroredRecords() async throws {
        let records = try await persistence.mirroredRecords(in: namespace)
        let identities = records.compactMap {
            localIdentity(from: $0)
        }
        try await persistence.reconcileCloudRecordNameIdentities(identities, in: namespace, maximumEntries: maximumEntries)
    }

    /// Explicit account/workspace teardown. The persistence store verifies its
    /// active lease before deleting any namespaced index rows.
    @discardableResult
    func purge(in requestedNamespace: PersistenceNamespace) async throws -> Int {
        try requireNamespace(requestedNamespace)
        return try await persistence.purgeCloudRecordNameIdentities(in: namespace)
    }

    private func requireNamespace(_ requestedNamespace: PersistenceNamespace) throws {
        guard requestedNamespace == namespace else {
            throw SwiftDataCloudRecordNameIdentityIndexError.namespaceMismatch
        }
    }

    private func mirroredIdentity(for recordName: String) async throws -> LocalCloudRecordNameIdentity? {
        let records = try await persistence.mirroredRecords(in: namespace)
        return records.lazy.compactMap { self.localIdentity(from: $0) }.first {
            $0.recordName == recordName
        }
    }

    private func localIdentity(from record: LocalMirrorRecord) -> LocalCloudRecordNameIdentity? {
        guard record.namespace == namespace,
            let systemFields = record.systemFields,
            !systemFields.isEmpty,
            let changeTag = record.changeTag,
            !changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            record.schemaVersion > 0,
            let recordType = cloudRecordType(for: record.recordType)
        else {
            return nil
        }
        return LocalCloudRecordNameIdentity(
            namespace: namespace,
            recordName: CloudRecordNaming.recordName(for: record.resourceKey, workspaceID: namespace.workspaceID),
            resourceKey: record.resourceKey,
            recordType: recordType,
            schemaVersion: record.schemaVersion,
            systemFields: systemFields,
            changeTag: changeTag
        )
    }

    private func localIdentity(from identity: CloudRecordNameIdentity) -> LocalCloudRecordNameIdentity {
        LocalCloudRecordNameIdentity(
            namespace: namespace, recordName: identity.recordName, resourceKey: identity.resourceKey, recordType: identity.recordType,
            schemaVersion: identity.schemaVersion, systemFields: identity.systemFields, changeTag: identity.changeTag
        )
    }

    private func cloudIdentity(from identity: LocalCloudRecordNameIdentity) throws -> CloudRecordNameIdentity {
        guard identity.namespace == namespace else {
            throw CloudRecordNameIdentityIndexError.invalidIdentity
        }
        try validateIdentity(
            recordName: identity.recordName, resourceKey: identity.resourceKey, recordType: identity.recordType,
            schemaVersion: identity.schemaVersion, systemFields: identity.systemFields, changeTag: identity.changeTag)
        return CloudRecordNameIdentity(
            recordName: identity.recordName, resourceKey: identity.resourceKey, recordType: identity.recordType,
            schemaVersion: identity.schemaVersion, systemFields: identity.systemFields, changeTag: identity.changeTag
        )
    }

    private func validateIdentity(
        recordName: String, resourceKey: ResourceKey, recordType: String, schemaVersion: Int, systemFields: Data, changeTag: String
    ) throws {
        guard let canonicalRecordType = CloudRecordNaming.canonicalRecordType(recordType),
            CloudRecordNaming.isValidRecordName(recordName),
            recordName == CloudRecordNaming.recordName(for: resourceKey, workspaceID: namespace.workspaceID),
            canonicalRecordType == recordType,
            schemaVersion > 0,
            !systemFields.isEmpty,
            !changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CloudRecordNameIdentityIndexError.invalidIdentity
        }
    }

    private func cloudRecordType(for persistedType: String) -> String? {
        let candidate: String
        switch persistedType {
        case LocalRecordKind.physicalTopology:
            candidate = WorkspaceRecordType.physicalTopology
        case LocalRecordKind.workOrder:
            candidate = CloudRecordNaming.workOrderRecordType
        case LocalRecordKind.auditEvent:
            candidate = CloudRecordNaming.auditRecordType
        case LocalRecordKind.prefix:
            candidate = WorkspaceRecordType.prefix
        default:
            candidate = persistedType
        }
        return CloudRecordNaming.canonicalRecordType(candidate)
    }
}
