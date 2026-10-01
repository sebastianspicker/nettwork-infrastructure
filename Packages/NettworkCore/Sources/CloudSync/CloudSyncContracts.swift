import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The CloudKit-independent record names used by every production adapter.
/// Names contain no user-controlled labels and remain stable across retries.
public enum CloudRecordNaming {
    public static let schemaVersion = 1
    public static let workspaceRecordType = WorkspaceRecordType.workspace
    public static let shareRecordType = WorkspaceRecordType.workspaceShare
    public static let workOrderRecordType = WorkspaceRecordType.workOrder
    public static let reservationLockRecordType = WorkspaceRecordType.resourceReservationLock
    public static let auditRecordType = WorkspaceRecordType.auditEvent
    public static let receiptRecordType = WorkspaceRecordType.operationReceipt
    public static let tombstoneRecordType = WorkspaceRecordType.tombstone
    public static let attachmentEvidenceQuotaLedgerRecordType = WorkspaceRecordType.attachmentEvidenceQuotaLedger
    public static let attachmentEvidenceReservationReleaseRecordType = WorkspaceRecordType.attachmentEvidenceReservationRelease
    public static let attachmentEvidenceBindingRecordType = WorkspaceRecordType.attachmentEvidenceBinding
    public static let floorPlanAssetBindingRecordType = AuthoritativeActivationMutation.floorPlanAssetBindingRecordType
    public static let workspaceAssetRecordType = WorkspaceRecordType.workspaceAsset
    public static let importedHistoricalReferenceRecordType = WorkspaceRecordType.importedHistoricalReference
    public static let workspaceTransferSessionRecordType = CloudStagedTransferRecordType.session
    public static let maximumRecordNameUTF8Length = 240
    public static let domainRecordTypes: Set<String> = [
        WorkspaceRecordType.location, WorkspaceRecordType.rack, WorkspaceRecordType.deviceType, WorkspaceRecordType.portTemplate,
        WorkspaceRecordType.moduleTemplate,
        WorkspaceRecordType.device, WorkspaceRecordType.module, WorkspaceRecordType.rackPlacement, WorkspaceRecordType.floorPlanAnchor,
        WorkspaceRecordType.port,
        WorkspaceRecordType.cable, WorkspaceRecordType.internalLink, WorkspaceRecordType.prefix, WorkspaceRecordType.vrf, WorkspaceRecordType.ipAddressRecord,
        WorkspaceRecordType.vlanGroup, WorkspaceRecordType.vlan, WorkspaceRecordType.interface, WorkspaceRecordType.ipAddressAssignment,
        WorkspaceRecordType.interfaceVLANMembership,
        WorkspaceRecordType.physicalTopology, WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.templatePlacementState,
        WorkspaceRecordType.topologyTombstone, WorkspaceRecordType.hierarchyTombstone,
        workspaceRecordType, shareRecordType, workOrderRecordType, reservationLockRecordType, auditRecordType, receiptRecordType, tombstoneRecordType,
        attachmentEvidenceQuotaLedgerRecordType, attachmentEvidenceReservationReleaseRecordType, attachmentEvidenceBindingRecordType,
        floorPlanAssetBindingRecordType, workspaceAssetRecordType, importedHistoricalReferenceRecordType,
        workspaceTransferSessionRecordType,
    ]

    public static func zoneName(for workspaceID: ObjectID) -> String { "nettwork.workspace.\(workspaceID.description)" }

    public static func recordName(for key: ResourceKey, workspaceID: ObjectID) -> String {
        recordName(forResourceKeyDescription: key.description, workspaceID: workspaceID)
    }

    /// Computes a record identity directly from the stored Cloud scalar. This
    /// lets maintenance validate a member without trusting a local mirror.
    public static func recordName(forResourceKeyDescription description: String, workspaceID: ObjectID) -> String {
        let digest = SHA256.hash(data: Data(description.utf8)).map { String(format: "%02x", $0) }.joined()
        return "nw.\(workspaceID.description).\(digest)"
    }

    public static func envelopeID(for key: ResourceKey, workspaceID: ObjectID) -> ObjectID {
        stableID(seed: "envelope\u{1F}\(workspaceID.description)\u{1F}\(key.description)")
    }

    public static func mutationID(for operationID: ObjectID) -> ObjectID {
        stableID(seed: "mutation\u{1F}\(operationID.description)")
    }

    public static func isValidRecordName(_ value: String) -> Bool {
        !value.isEmpty && value.lengthOfBytes(using: .utf8) <= maximumRecordNameUTF8Length
    }

    /// Temporary source names used by the domain are normalized at this one
    /// boundary; unknown record types are never uploaded as ad-hoc schema.
    public static func canonicalRecordType(_ sourceType: String) -> String? {
        if domainRecordTypes.contains(sourceType) { return sourceType }
        let candidate = "Nettwork\(sourceType.trimmingCharacters(in: .whitespacesAndNewlines))"
        return domainRecordTypes.contains(candidate) ? candidate : nil
    }

    private static func stableID(seed: String) -> ObjectID {
        let hex = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("A SHA-256-derived UUID must be syntactically valid.")
        }
        return ObjectID(uuid)
    }
}
public struct CloudRecordSchema: Codable, Hashable, Sendable {
    public let recordType: String
    public let schemaVersion: Int
    public let maximumPayloadBytes: Int
    public let allowsTombstone: Bool

    public init(recordType: String, schemaVersion: Int = CloudRecordNaming.schemaVersion, maximumPayloadBytes: Int = 1_048_576, allowsTombstone: Bool = true) {
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.maximumPayloadBytes = maximumPayloadBytes
        self.allowsTombstone = allowsTombstone
    }

    public static let authoritative: Set<CloudRecordSchema> = Set<CloudRecordSchema>(
        CloudRecordNaming.domainRecordTypes.map {
            CloudRecordSchema(
                recordType: $0,
                allowsTombstone: ![
                    CloudRecordNaming.workspaceRecordType,
                    CloudRecordNaming.shareRecordType, CloudRecordNaming.auditRecordType,
                    CloudRecordNaming.receiptRecordType, CloudRecordNaming.tombstoneRecordType,
                    CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType,
                    CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType,
                    CloudRecordNaming.attachmentEvidenceBindingRecordType,
                    CloudRecordNaming.floorPlanAssetBindingRecordType,
                    CloudRecordNaming.workspaceTransferSessionRecordType,
                ].contains($0))
        })
}

public struct CloudWorkspaceRecord: Codable, Hashable, Sendable {
    public let workspaceID: ObjectID
    public let zoneName: String
    public let zoneOwnerRecordName: String
    public let lifecycle: WorkspaceLifecycle
    public init(workspaceID: ObjectID, zoneName: String, zoneOwnerRecordName: String, lifecycle: WorkspaceLifecycle = .empty(epoch: 0)) {
        self.workspaceID = workspaceID
        self.zoneName = zoneName
        self.zoneOwnerRecordName = zoneOwnerRecordName
        self.lifecycle = lifecycle
    }

    private enum CodingKeys: String, CodingKey { case workspaceID, zoneName, zoneOwnerRecordName, lifecycle }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workspaceID: try container.decode(ObjectID.self, forKey: .workspaceID),
            zoneName: try container.decode(String.self, forKey: .zoneName),
            zoneOwnerRecordName: try container.decode(String.self, forKey: .zoneOwnerRecordName),
            lifecycle: try container.decodeIfPresent(WorkspaceLifecycle.self, forKey: .lifecycle) ?? .empty(epoch: 0)
        )
    }
}

public struct CloudWorkspaceShareRecord: Codable, Hashable, Sendable {
    public let workspaceID: ObjectID
    public let shareRecordName: String
    public let permission: WorkspaceSharePermission
    public init(workspaceID: ObjectID, shareRecordName: String, permission: WorkspaceSharePermission) {
        self.workspaceID = workspaceID
        self.shareRecordName = shareRecordName
        self.permission = permission
    }
}

public enum CloudWorkspaceAssetRecordError: Error, Hashable, Sendable {
    case invalidIdentity
    case invalidPath
    case invalidMetadata
}

/// Canonical metadata for a workspace-owned binary restored from an archive.
/// The bytes travel in `CloudRecordEnvelope.recordAsset`; the payload commits
/// their stable ID, archive path, type, size, and hash without duplicating them.
public struct CloudWorkspaceAssetRecord: Codable, Hashable, Sendable {
    public let assetID: ObjectID
    public let relativePath: String
    public let metadata: CloudRecordAssetMetadata

    public init(assetID: ObjectID, relativePath: String, metadata: CloudRecordAssetMetadata) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard metadata.id == assetID else { throw CloudWorkspaceAssetRecordError.invalidIdentity }
        guard !relativePath.isEmpty, relativePath.utf8.count <= 1_024, !relativePath.hasPrefix("/"),
            !relativePath.hasSuffix("/"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            !relativePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw CloudWorkspaceAssetRecordError.invalidPath
        }
        guard metadata.byteCount > 0,
            !metadata.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CloudWorkspaceAssetRecordError.invalidMetadata
        }
        self.assetID = assetID
        self.relativePath = relativePath
        self.metadata = metadata
    }

    public var resourceKey: ResourceKey {
        .string("workspace-asset:\(assetID.description)")
    }
}

/// Controls whether a record writes its supplied binary and presentation
/// fields or retains the values archived in its exact CloudKit precondition.
///
/// `assertionPreserving` is reserved for condition-only read assertions. It
/// requires an exact precondition because it can only preserve a record that
/// already exists. A business save always uses `businessSave`, where a nil
/// `recordAsset` intentionally clears the prior CKAsset and its metadata.
public enum CloudRecordWriteMode: String, Codable, Hashable, Sendable {
    case businessSave
    case assertionPreserving
}

public struct CloudRecordEnvelope: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public var recordName: String
    public var resourceKey: ResourceKey
    public var workspaceID: ObjectID
    public var recordType: String
    public var schemaVersion: Int
    public var payload: Data
    /// Optional binary field belonging to this exact record. The transport
    /// must submit it in the same atomic mutation as its metadata.
    public var recordAsset: CloudRecordAssetDescriptor?
    /// Read assertions retain asset, visibility, and associated metadata from
    /// the exact record restored by their conditional precondition.
    public var writeMode: CloudRecordWriteMode
    public var visibility: WorkspaceRecordVisibility
    public var systemFields: Data
    public var changeTag: String
    public var isDeleted: Bool

    public init(
        id _: ObjectID? = nil, recordName _: String? = nil, resourceKey: ResourceKey, workspaceID: ObjectID, recordType: String,
        schemaVersion: Int = CloudRecordNaming.schemaVersion, payload: Data,
        recordAsset: CloudRecordAssetDescriptor? = nil, writeMode: CloudRecordWriteMode = .businessSave, visibility: WorkspaceRecordVisibility = .live,
        systemFields: Data, changeTag: String, isDeleted: Bool = false
    ) {
        self.resourceKey = resourceKey
        self.workspaceID = workspaceID
        self.id = CloudRecordNaming.envelopeID(for: resourceKey, workspaceID: workspaceID)
        self.recordName = CloudRecordNaming.recordName(for: self.resourceKey, workspaceID: self.workspaceID)
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.recordAsset = recordAsset
        self.writeMode = writeMode
        self.visibility = visibility
        self.systemFields = systemFields
        self.changeTag = changeTag
        self.isDeleted = isDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordName, resourceKey, workspaceID, recordType, schemaVersion,
            payload, recordAsset, writeMode, visibility, systemFields, changeTag, isDeleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            resourceKey: try container.decode(ResourceKey.self, forKey: .resourceKey),
            workspaceID: try container.decode(ObjectID.self, forKey: .workspaceID),
            recordType: try container.decode(String.self, forKey: .recordType),
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            payload: try container.decode(Data.self, forKey: .payload),
            recordAsset: try container.decodeIfPresent(CloudRecordAssetDescriptor.self, forKey: .recordAsset),
            writeMode: try container.decodeIfPresent(CloudRecordWriteMode.self, forKey: .writeMode) ?? .businessSave,
            visibility: try container.decodeIfPresent(WorkspaceRecordVisibility.self, forKey: .visibility) ?? .live,
            systemFields: try container.decode(Data.self, forKey: .systemFields),
            changeTag: try container.decode(String.self, forKey: .changeTag),
            isDeleted: try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(recordName, forKey: .recordName)
        try container.encode(resourceKey, forKey: .resourceKey)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(recordType, forKey: .recordType)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(recordAsset, forKey: .recordAsset)
        try container.encode(writeMode, forKey: .writeMode)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(systemFields, forKey: .systemFields)
        try container.encode(changeTag, forKey: .changeTag)
        try container.encode(isDeleted, forKey: .isDeleted)
    }
}
