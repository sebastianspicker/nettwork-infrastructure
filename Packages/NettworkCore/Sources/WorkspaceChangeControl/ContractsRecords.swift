import CryptoKit
import Foundation
/// This receipt has no clock or transport generated value, so retries are exact.
import NetworkModel

public struct AuthoritativeWorkspaceZone: Codable, Hashable, Sendable {
    public let workspaceID: ObjectID
    public let containerIdentifier: String
    public let zoneName: String
    public let zoneOwnerRecordName: String
    public init(workspaceID: ObjectID, containerIdentifier: String, zoneName: String, zoneOwnerRecordName: String) {
        self.workspaceID = workspaceID
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.zoneOwnerRecordName = zoneOwnerRecordName
    }
}

public struct ActorInstallationSnapshot: Codable, Hashable, Sendable {
    public let actorID: String
    public let installationID: String
    public let sessionID: String
    public let sessionGeneration: UInt64
    public let capturedAt: Date
    public init(actorID: String, installationID: String, sessionID: String, sessionGeneration: UInt64, capturedAt: Date) {
        self.actorID = actorID
        self.installationID = installationID
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.capturedAt = capturedAt
    }
}

/// Exact opaque server metadata required for a non-create conditional write.
public struct ExactRecordPrecondition: Codable, Hashable, Sendable {
    public let systemFields: Data
    public let changeTag: String
    public init(systemFields: Data, changeTag: String) {
        self.systemFields = systemFields
        self.changeTag = changeTag
    }
}

public enum MutationPrecondition: Codable, Hashable, Sendable {
    case mustNotExist(ResourceKey)
    case exactSystemFields(ResourceKey, ExactRecordPrecondition)
    public var resourceKey: ResourceKey {
        switch self {
        case .mustNotExist(let key), .exactSystemFields(let key, _): key
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, resourceKey, exact }
    private enum Kind: String, Codable { case mustNotExist, exactSystemFields }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(ResourceKey.self, forKey: .resourceKey)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .mustNotExist: self = .mustNotExist(key)
        case .exactSystemFields: self = .exactSystemFields(key, try container.decode(ExactRecordPrecondition.self, forKey: .exact))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mustNotExist(let key):
            try container.encode(Kind.mustNotExist, forKey: .kind)
            try container.encode(key, forKey: .resourceKey)
        case let .exactSystemFields(key, exact):
            try container.encode(Kind.exactSystemFields, forKey: .kind)
            try container.encode(key, forKey: .resourceKey)
            try container.encode(exact, forKey: .exact)
        }
    }
}

/// A bounded binary field that travels with the single authoritative record it
/// authenticates. Inline bytes are immutable and retry-safe; a durable file
/// capability is checked against the same SHA-256 immediately before the
/// transport creates its temporary CloudKit asset file. This contract remains
/// intentionally record-generic so archive restore can use it without a new
/// side channel.
public struct CloudRecordAssetMetadata: Codable, Hashable, Sendable {
    public static let maximumByteCount = 32 * 1_024 * 1_024
    /// Caller-owned immutable identity, retained across retries and usable by
    /// future archive restore without inferring identity from a file name.
    public let id: ObjectID
    public let fieldName: String
    public let sha256: String
    public let contentType: String
    public let byteCount: Int

    public init(id: ObjectID, fieldName: String, sha256: String, contentType: String, byteCount: Int) throws {
        let normalizedFieldName = fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = sha256.lowercased()
        let type = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFieldName.isEmpty,
            normalizedFieldName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
            normalizedFieldName != "assetMetadata",
            digest.count == 64,
            digest.allSatisfy(\.isHexDigit),
            !type.isEmpty,
            (1...Self.maximumByteCount).contains(byteCount)
        else {
            throw AuthoritativeRecordAssetError.invalidDescriptor
        }
        self.id = id
        self.fieldName = normalizedFieldName
        self.sha256 = digest
        self.contentType = type
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey { case id, fieldName, sha256, contentType, byteCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ObjectID.self, forKey: .id),
            fieldName: container.decode(String.self, forKey: .fieldName),
            sha256: container.decode(String.self, forKey: .sha256),
            contentType: container.decode(String.self, forKey: .contentType),
            byteCount: container.decode(Int.self, forKey: .byteCount))
    }
}

public struct CloudRecordAssetDescriptor: Codable, Hashable, Sendable {
    public enum Storage: Codable, Hashable, Sendable {
        case inline(Data)
        case durableFile(URL)
    }

    public let metadata: CloudRecordAssetMetadata
    public let storage: Storage

    public init(
        id: ObjectID, fieldName: String, sha256: String, contentType: String, byteCount: Int,
        storage: Storage
    ) throws {
        let metadata = try CloudRecordAssetMetadata(
            id: id, fieldName: fieldName, sha256: sha256,
            contentType: contentType, byteCount: byteCount)
        if case let .inline(bytes) = storage {
            guard bytes.count == metadata.byteCount, Self.sha256(for: bytes) == metadata.sha256 else {
                throw AuthoritativeRecordAssetError.invalidInlineBytes
            }
        }
        if case let .durableFile(url) = storage, !url.isFileURL {
            throw AuthoritativeRecordAssetError.invalidFileCapability
        }
        self.metadata = metadata
        self.storage = storage
    }

    public init(metadata: CloudRecordAssetMetadata, storage: Storage) throws {
        try self.init(
            id: metadata.id, fieldName: metadata.fieldName, sha256: metadata.sha256,
            contentType: metadata.contentType, byteCount: metadata.byteCount, storage: storage)
    }

    public var fieldName: String { metadata.fieldName }
    public var sha256: String { metadata.sha256 }
    public var contentType: String { metadata.contentType }
    public var byteCount: Int { metadata.byteCount }

    private enum CodingKeys: String, CodingKey { case metadata, storage }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(CloudRecordAssetMetadata.self, forKey: .metadata),
            storage: container.decode(Storage.self, forKey: .storage))
    }

    /// Resolves exactly once at the boundary that needs bytes. A durable file
    /// is not trusted merely because its URL was serialized: its bounded bytes
    /// must still match the descriptor's SHA-256.
    public func validatedBytes() throws -> Data {
        let bytes: Data
        switch storage {
        case let .inline(value): bytes = value
        case let .durableFile(url):
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == metadata.byteCount else {
                throw AuthoritativeRecordAssetError.invalidFileCapability
            }
            bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard bytes.count == metadata.byteCount, bytes.count <= CloudRecordAssetMetadata.maximumByteCount,
            Self.sha256(for: bytes) == metadata.sha256
        else {
            throw AuthoritativeRecordAssetError.digestMismatch
        }
        return bytes
    }

    public static func sha256(for bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AuthoritativeRecordAssetError: Error, Hashable, Sendable {
    case invalidDescriptor
    case invalidInlineBytes
    case invalidFileCapability
    case digestMismatch
}

public struct AuthoritativeRecordSave: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let encodedRecord: Data
    /// This is never a free-standing side write: when present it is attached
    /// to this exact save by the atomic transport.
    public let recordAsset: CloudRecordAssetDescriptor?

    public init(
        resourceKey: ResourceKey, recordType: String, schemaVersion: Int, encodedRecord: Data,
        recordAsset: CloudRecordAssetDescriptor? = nil
    ) {
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.encodedRecord = encodedRecord
        self.recordAsset = recordAsset
    }

    private enum CodingKeys: String, CodingKey {
        case resourceKey, recordType, schemaVersion, encodedRecord, recordAsset
    }

    /// Existing durable outbox values predate assets. Their absence remains an
    /// explicit no-asset save rather than making old work unrecoverable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            resourceKey: try container.decode(ResourceKey.self, forKey: .resourceKey),
            recordType: try container.decode(String.self, forKey: .recordType),
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            encodedRecord: try container.decode(Data.self, forKey: .encodedRecord),
            recordAsset: try container.decodeIfPresent(CloudRecordAssetDescriptor.self, forKey: .recordAsset)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resourceKey, forKey: .resourceKey)
        try container.encode(recordType, forKey: .recordType)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(encodedRecord, forKey: .encodedRecord)
        try container.encodeIfPresent(recordAsset, forKey: .recordAsset)
    }
}

public struct AuthoritativeTombstone: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let recordType: String
    public let deletedAt: Date
    public let encodedTombstone: Data
    public init(resourceKey: ResourceKey, recordType: String, deletedAt: Date, encodedTombstone: Data) {
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.deletedAt = deletedAt
        self.encodedTombstone = encodedTombstone
    }
}

/// An immutable, exact server record that a mutation reads without changing.
/// The record is conditionally saved with its original payload so CloudKit
/// rejects the whole mutation when the read dependency has changed.
public struct AuthoritativeReadAssertion: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let encodedRecord: Data
    public let precondition: ExactRecordPrecondition

    public init(
        resourceKey: ResourceKey, recordType: String, schemaVersion: Int, encodedRecord: Data,
        precondition: ExactRecordPrecondition
    ) {
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.encodedRecord = encodedRecord
        self.precondition = precondition
    }
}

/// Visibility is carried with every mirrored record, not inferred from a
/// record-name convention. Older durable records decode as live so a schema
/// upgrade never hides an already-visible workspace.
public enum WorkspaceRecordVisibility: Hashable, Sendable, Codable {
    case live
    case staged(transferID: ObjectID)

    private enum CodingKeys: String, CodingKey { case kind, transferID }
    private enum Kind: String, Codable { case live, staged }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) else {
            self = .live
            return
        }
        switch kind {
        case .live: self = .live
        case .staged: self = .staged(transferID: try container.decode(ObjectID.self, forKey: .transferID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .live: try container.encode(Kind.live, forKey: .kind)
        case let .staged(transferID):
            try container.encode(Kind.staged, forKey: .kind)
            try container.encode(transferID, forKey: .transferID)
        }
    }
}

/// A durable workspace starts empty at a monotonic epoch. Its only visibility
/// transition is an activation commit that names the verified transfer.
public struct WorkspaceActivationCommit: Codable, Hashable, Sendable {
    public let transferID: ObjectID
    public let memberCount: Int
    public let rollingDigest: String

    public init(transferID: ObjectID, memberCount: Int, rollingDigest: String) {
        self.transferID = transferID
        self.memberCount = memberCount
        self.rollingDigest = rollingDigest
    }
}

public enum WorkspaceLifecycle: Codable, Hashable, Sendable {
    case empty(epoch: UInt64)
    case active(commit: WorkspaceActivationCommit)

    private enum CodingKeys: String, CodingKey { case kind, epoch, commit }
    private enum Kind: String, Codable { case empty, active }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .empty: self = .empty(epoch: try container.decode(UInt64.self, forKey: .epoch))
        case .active: self = .active(commit: try container.decode(WorkspaceActivationCommit.self, forKey: .commit))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .empty(epoch):
            try container.encode(Kind.empty, forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
        case let .active(commit):
            try container.encode(Kind.active, forKey: .kind)
            try container.encode(commit, forKey: .commit)
        }
    }
}
