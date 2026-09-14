import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

public enum LocalMirrorMaintenanceLimits {
    public static let schemaVersion = 9
    public static let maximumTransferMembers = 200
}

public struct LocalMirrorReferenceEdge: Hashable, Sendable {
    public let source: ResourceKey
    public let target: ResourceKey
    public init(source: ResourceKey, target: ResourceKey) {
        self.source = source
        self.target = target
    }
}

public struct LocalMirrorTransferMember: Hashable, Sendable {
    public let transferID: ObjectID
    public let resourceKey: ResourceKey
    public let digest: String
    public init(transferID: ObjectID, resourceKey: ResourceKey, digest: String) {
        self.transferID = transferID
        self.resourceKey = resourceKey
        self.digest = digest
    }
}

public struct LocalMirrorMaintenanceRecord: Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let references: Set<LocalMirrorReferenceEdge>
    public let transferMember: LocalMirrorTransferMember?
    public init(resourceKey: ResourceKey, references: Set<LocalMirrorReferenceEdge> = [], transferMember: LocalMirrorTransferMember? = nil) {
        self.resourceKey = resourceKey
        self.references = references
        self.transferMember = transferMember
    }
}

public struct LocalMirrorMaintenanceBatch: Hashable, Sendable {
    public let records: [LocalMirrorMaintenanceRecord]
    /// A compatibility caller that cannot provide every V9 fact must not make
    /// the index look complete. The next explicit repair is the only full
    /// mirror read permitted to repair it.
    public let isComplete: Bool
    public init(records: [LocalMirrorMaintenanceRecord], isComplete: Bool = true) {
        self.records = records
        self.isComplete = isComplete
    }
}

@Model
public final class LocalMirrorReferenceEdgeModel {
    #Index<LocalMirrorReferenceEdgeModel>([\.namespaceKey, \.sourceKey], [\.namespaceKey, \.targetKey])
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var sourceKey: String
    public var targetKey: String
    public var sourceKeyData: Data
    public var targetKeyData: Data

    public init(namespace: PersistenceNamespace, edge: LocalMirrorReferenceEdge) throws {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace, identity: "mirror-reference:\(edge.source.description):\(edge.target.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        sourceKey = edge.source.description
        targetKey = edge.target.description
        sourceKeyData = try PersistenceCoding.encode(edge.source)
        targetKeyData = try PersistenceCoding.encode(edge.target)
    }
}

/// A single asset ID has one authoritative mirror owner in one namespace.
/// `transferID` is retained so per-transfer quotas never need a payload scan.
@Model
public final class LocalMirrorAssetOwnerModel {
    #Index<LocalMirrorAssetOwnerModel>([\.namespaceKey, \.ownerKey], [\.namespaceKey, \.transferID])
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var assetID: String
    public var ownerKey: String
    public var ownerKeyData: Data
    public var transferID: String?
    public var byteCount: Int

    public init(namespace: PersistenceNamespace, assetID: ObjectID, ownerKey: ResourceKey, transferID: ObjectID?, byteCount: Int) throws {
        storageKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "mirror-asset-owner:\(assetID.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.assetID = assetID.description
        self.ownerKey = ownerKey.description
        ownerKeyData = try PersistenceCoding.encode(ownerKey)
        self.transferID = transferID?.description
        self.byteCount = byteCount
    }
}

@Model
public final class LocalMirrorTransferMemberModel {
    #Index<LocalMirrorTransferMemberModel>([\.namespaceKey, \.transferID])
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var transferID: String
    public var resourceKeyData: Data
    public var resourceKey: String
    public var digest: String

    public init(namespace: PersistenceNamespace, member: LocalMirrorTransferMember) throws {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace, identity: "mirror-transfer-member:\(member.transferID.description):\(member.resourceKey.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        transferID = member.transferID.description
        resourceKeyData = try PersistenceCoding.encode(member.resourceKey)
        resourceKey = member.resourceKey.description
        digest = member.digest
    }
}

@Model
public final class LocalMirrorAssetUsageModel {
    @Attribute(.unique) public var namespaceKey: String
    public var assetCount: Int
    public var byteCount: Int
    public var updatedAt: Date
    public init(namespace: PersistenceNamespace, assetCount: Int = 0, byteCount: Int = 0) {
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.assetCount = assetCount
        self.byteCount = byteCount
        updatedAt = .now
    }
}

@Model
public final class LocalMirrorTransferAssetUsageModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var transferID: String
    public var assetCount: Int
    public var byteCount: Int
    public var updatedAt: Date
    public init(namespace: PersistenceNamespace, transferID: ObjectID, assetCount: Int = 0, byteCount: Int = 0) {
        storageKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "mirror-transfer-asset-usage:\(transferID.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        self.transferID = transferID.description
        self.assetCount = assetCount
        self.byteCount = byteCount
        updatedAt = .now
    }
}

@Model
public final class LocalMirrorMaintenanceStateModel {
    @Attribute(.unique) public var namespaceKey: String
    public var schemaVersion: Int
    public var isComplete: Bool
    public var referenceEdgeCount: Int
    public var assetOwnerCount: Int
    public var transferMemberCount: Int
    public var updatedAt: Date
    public init(namespace: PersistenceNamespace, isComplete: Bool = false) {
        namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        schemaVersion = LocalMirrorMaintenanceLimits.schemaVersion
        self.isComplete = isComplete
        referenceEdgeCount = 0
        assetOwnerCount = 0
        transferMemberCount = 0
        updatedAt = .now
    }
}

@Model
public final class LocalAttachmentEvidenceReservationModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var reservationData: Data
    public var reservationID: String
    public var attachmentID: String
    public var workOrderID: String
    public var expiresAt: Date

    public init(reservation: AttachmentEvidenceReservationMetadata) throws {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: reservation.namespace,
            identity: "attachment-reservation:\(reservation.attachmentID.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: reservation.namespace)
        reservationData = try PersistenceCoding.encode(reservation)
        reservationID = reservation.id.description
        attachmentID = reservation.attachmentID.description
        workOrderID = reservation.workOrderID.description
        expiresAt = reservation.expiresAt
    }
}

@Model
public final class LocalAttachmentEvidenceModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var evidenceData: Data
    public var attachmentID: String
    public var workOrderID: String
    public var boundAt: Date

    public init(metadata: AttachmentEvidenceMetadata) throws {
        storageKey = PersistenceNamespaceKey.storageKey(
            namespace: metadata.namespace,
            identity: "attachment-evidence:\(metadata.attachmentID.description)")
        namespaceKey = PersistenceNamespaceKey.value(for: metadata.namespace)
        evidenceData = try PersistenceCoding.encode(metadata)
        attachmentID = metadata.attachmentID.description
        workOrderID = metadata.workOrderID.description
        boundAt = metadata.boundAt
    }
}

@Model
public final class LocalQuarantineModel {
    @Attribute(.unique) public var storageKey: String
    public var namespaceKey: String
    public var recordData: Data
    public var capturedAt: Date

    public init(record: LocalQuarantineRecord) throws {
        self.storageKey = PersistenceNamespaceKey.storageKey(namespace: record.namespace, identity: "quarantine:\(record.id.description)")
        self.namespaceKey = PersistenceNamespaceKey.value(for: record.namespace)
        self.recordData = try PersistenceCoding.encode(record)
        self.capturedAt = record.capturedAt
    }
}
