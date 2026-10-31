import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Typed, fail-closed failures of the durable local record store. None of them
/// is ever mapped to an empty store: an unreadable store stays unreadable.
public enum LocalWorkspaceRecordStoreError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case corruptSnapshot
    case snapshotTooLarge(byteCount: Int)
    case assetMissing(sha256: String)
    case assetIntegrityFailure(sha256: String)
    case invalidRecord(recordName: String)
    case duplicateRecord(recordName: String)
    case emptyMutation
    case revisionConflict(expected: UInt64, actual: UInt64)
    case revisionOverflow
    case readFailed(String)
    case writeFailed(String)
}

extension LocalWorkspaceRecordStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version): "The local workspace store uses unsupported format version \(version)."
        case .corruptSnapshot: "The local workspace store snapshot is corrupt and was not loaded."
        case .snapshotTooLarge(let byteCount): "The local workspace store snapshot (\(byteCount) bytes) exceeds the size limit."
        case .assetMissing(let sha256): "The local workspace store is missing asset \(sha256)."
        case .assetIntegrityFailure(let sha256): "The local workspace store asset \(sha256) does not match its digest."
        case .invalidRecord(let recordName): "The record \(recordName) is not valid for the local workspace store."
        case .duplicateRecord(let recordName): "The mutation writes record \(recordName) more than once."
        case .emptyMutation: "The local workspace store mutation contains no records."
        case .revisionConflict(let expected, let actual): "The local workspace store is at revision \(actual), not the expected \(expected)."
        case .revisionOverflow: "The local workspace store revision counter is exhausted."
        case .readFailed(let reason): "The local workspace store could not be read: \(reason)"
        case .writeFailed(let reason): "The local workspace store could not be written: \(reason)"
        }
    }
}

/// One persisted server-side record. Asset bytes live content-addressed on
/// disk; the record only carries their verified metadata.
public struct LocalStoredRecord: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let workspaceID: ObjectID
    public let recordType: String
    public let schemaVersion: Int
    public let payload: Data
    public let visibility: WorkspaceRecordVisibility
    public let asset: CloudRecordAssetMetadata?
    public let isDeleted: Bool
    /// Opaque to the store; the transport defines and compares it.
    public let systemFields: Data
    public let changeTag: String
    public let serverModifiedAt: Date
    /// Store revision of the commit that last wrote this record.
    public let changedAtRevision: UInt64

    public init(
        resourceKey: ResourceKey, workspaceID: ObjectID, recordType: String, schemaVersion: Int, payload: Data,
        visibility: WorkspaceRecordVisibility = .live, asset: CloudRecordAssetMetadata? = nil, isDeleted: Bool = false, systemFields: Data,
        changeTag: String, serverModifiedAt: Date, changedAtRevision: UInt64 = 0
    ) {
        self.resourceKey = resourceKey
        self.workspaceID = workspaceID
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.visibility = visibility
        self.asset = asset
        self.isDeleted = isDeleted
        self.systemFields = systemFields
        self.changeTag = changeTag
        self.serverModifiedAt = serverModifiedAt
        self.changedAtRevision = changedAtRevision
    }

    public var recordName: String { CloudRecordNaming.recordName(for: resourceKey, workspaceID: workspaceID) }

    func stamped(at revision: UInt64) -> LocalStoredRecord {
        LocalStoredRecord(
            resourceKey: resourceKey, workspaceID: workspaceID, recordType: recordType, schemaVersion: schemaVersion, payload: payload,
            visibility: visibility, asset: asset, isDeleted: isDeleted, systemFields: systemFields, changeTag: changeTag,
            serverModifiedAt: serverModifiedAt, changedAtRevision: revision)
    }
}

/// A record to write plus the bytes of its asset (required exactly when the record names one).
public struct LocalRecordWrite: Hashable, Sendable {
    public let record: LocalStoredRecord
    public let assetBytes: Data?

    public init(record: LocalStoredRecord, assetBytes: Data? = nil) {
        self.record = record
        self.assetBytes = assetBytes
    }
}

/// A set of record writes that commits entirely or not at all. When
/// `expectedRevision` is set the commit fails if another commit intervened.
public struct LocalWorkspaceMutation: Hashable, Sendable {
    public let writes: [LocalRecordWrite]
    public let expectedRevision: UInt64?

    public init(writes: [LocalRecordWrite], expectedRevision: UInt64? = nil) {
        self.writes = writes
        self.expectedRevision = expectedRevision
    }
}

/// Outcome of a successful commit: the new revision and the stamped records.
public struct LocalWorkspaceCommit: Hashable, Sendable {
    public let revision: UInt64
    public let records: [LocalStoredRecord]
}

/// Versioned on-disk snapshot (`formatVersion` 1), also the public read view of the store.
public struct LocalWorkspaceRecordSnapshot: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let incarnation: UUID
    public let revision: UInt64
    /// Ordered by record name, including tombstones.
    public let records: [LocalStoredRecord]

    init(incarnation: UUID, revision: UInt64, records: [LocalStoredRecord]) {
        self.formatVersion = Self.currentFormatVersion
        self.incarnation = incarnation
        self.revision = revision
        self.records = records.sorted { $0.recordName < $1.recordName }
    }
}
