import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Metadata retained for a real CloudKit deletion event. CloudKit deletion
/// callbacks expose a record name and type, not the domain `ResourceKey` or
/// the conditional metadata required by the mirror validator.
public struct CloudRecordNameIdentity: Codable, Hashable, Sendable {
    public let recordName: String
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let systemFields: Data
    public let changeTag: String

    public init(
        recordName: String, resourceKey: ResourceKey, recordType: String, schemaVersion: Int,
        systemFields: Data, changeTag: String
    ) {
        self.recordName = recordName
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.systemFields = systemFields
        self.changeTag = changeTag
    }
}

/// A production implementation must store this mapping durably in the same
/// account/workspace namespace as its mirror. A deletion is rejected when its
/// identity is unavailable; record-name hashes are deliberately never reversed.
public protocol CloudRecordNameIdentityIndex: Sendable {
    func identity(for recordName: String, in namespace: PersistenceNamespace) async throws -> CloudRecordNameIdentity?
    func store(
        _ identity: CloudRecordNameIdentity, in namespace: PersistenceNamespace, maximumEntries: Int
    ) async throws
}

public enum CloudRecordNameIdentityIndexError: Error, Hashable, Sendable {
    case invalidMaximumEntries
    case invalidIdentity
}

/// A bounded index intended for previews and tests. It is intentionally not a
/// production default: app composition must inject a durable implementation.
public actor BoundedCloudRecordNameIdentityIndex: CloudRecordNameIdentityIndex {
    private struct Entry: Sendable {
        let identity: CloudRecordNameIdentity
        let sequence: UInt64
    }

    private var entries: [PersistenceNamespace: [String: Entry]] = [:]
    private var nextSequence: UInt64 = 0

    public init() {}

    public func identity(for recordName: String, in namespace: PersistenceNamespace) async throws -> CloudRecordNameIdentity? {
        entries[namespace]?[recordName]?.identity
    }

    public func store(
        _ identity: CloudRecordNameIdentity, in namespace: PersistenceNamespace,
        maximumEntries: Int
    ) async throws {
        guard maximumEntries > 0 else { throw CloudRecordNameIdentityIndexError.invalidMaximumEntries }
        guard CloudRecordNaming.isValidRecordName(identity.recordName),
            identity.recordName == CloudRecordNaming.recordName(for: identity.resourceKey, workspaceID: namespace.workspaceID),
            identity.schemaVersion > 0,
            !identity.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CloudRecordNameIdentityIndexError.invalidIdentity
        }

        nextSequence &+= 1
        var scoped = entries[namespace] ?? [:]
        scoped[identity.recordName] = Entry(identity: identity, sequence: nextSequence)
        while scoped.count > maximumEntries,
            let eviction = scoped.min(by: { $0.value.sequence < $1.value.sequence })?.key
        {
            scoped.removeValue(forKey: eviction)
        }
        entries[namespace] = scoped
    }
}
