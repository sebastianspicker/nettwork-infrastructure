import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The stable record names used by a workspace transfer. These are deliberately
/// the same canonical names used at the authoritative sync boundary.
public enum WorkspaceTransferRecordType: String, Codable, CaseIterable, Sendable {
    case location = "NettworkLocation"
    case rack = "NettworkRack"
    case deviceType = "NettworkDeviceType"
    case portTemplate = "NettworkPortTemplate"
    case moduleTemplate = "NettworkModuleTemplate"
    case device = "NettworkDevice"
    case module = "NettworkModule"
    case rackPlacement = "NettworkRackPlacement"
    case port = "NettworkPort"
    case internalLink = "NettworkInternalLink"
    case cable = "NettworkCable"
    case vrf = "NettworkVRF"
    case prefix = "NettworkPrefix"
    case address = "NettworkIPAddressRecord"
    case vlanGroup = "NettworkVLANGroup"
    case vlan = "NettworkVLAN"
    case interface = "NettworkInterface"
    case assignment = "NettworkIPAddressAssignment"
    case floorPlanAnchor = "NettworkFloorPlanAnchor"
    case membership = "NettworkInterfaceVLANMembership"
    /// Operational state is archive-only. CSV remains the published domain
    /// table format and must never manufacture these authoritative records.
    case workOrder = "NettworkWorkOrder"
    case reservationLock = "NettworkResourceReservationLock"
    case operationReceipt = "NettworkOperationReceipt"
    case attachmentEvidenceQuotaLedger = "NettworkAttachmentEvidenceQuotaLedger"
    case attachmentEvidenceReservationRelease = "NettworkAttachmentEvidenceReservationRelease"
    case attachmentEvidenceBinding = "NettworkAttachmentEvidenceBinding"
    case floorPlanAssetBinding = "NettworkFloorPlanAssetBinding"
    /// A tombstoned, non-projecting proof that an immutable imported audit may
    /// refer to a source-only control record omitted from the target workspace.
    case importedHistoricalReference = "NettworkImportedHistoricalReference"

    public static let csvReconstructionTypes: Set<WorkspaceTransferRecordType> = [
        .location, .rack, .deviceType, .moduleTemplate, .device, .module,
        .rackPlacement, .port, .internalLink, .cable, .vrf, .prefix,
        .address, .vlanGroup, .vlan, .interface, .assignment, .floorPlanAnchor, .membership,
    ]
}

public typealias WorkspaceImportedHistoricalReference = ImportedHistoricalReferenceRecord

public struct WorkspaceTransferTombstone: Codable, Hashable, Sendable {
    public let deletedAt: Date

    public init(deletedAt: Date) {
        self.deletedAt = deletedAt
    }
}

/// Canonical payload for a CloudKit hard deletion whose deleted business
/// record no longer has payload bytes. It preserves only deletion identity and
/// time; it can never project as a live domain value.
public struct WorkspaceHardDeleteMarker: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let recordType: WorkspaceTransferRecordType
    public let deletedAt: Date

    public init(resourceKey: ResourceKey, recordType: WorkspaceTransferRecordType, deletedAt: Date) {
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.deletedAt = deletedAt
    }
}

/// One JSONL row in an archive or a staged workspace transfer. `payload` is
/// canonical JSON for the typed domain value, not a CSV row or an opaque
/// source-specific blob.
public struct WorkspaceTransferRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let resourceKey: ResourceKey
    public let recordType: WorkspaceTransferRecordType
    public let schemaVersion: Int
    public let payload: Data
    public let tombstone: WorkspaceTransferTombstone?

    public init(
        resourceKey: ResourceKey, recordType: WorkspaceTransferRecordType,
        schemaVersion: Int = currentSchemaVersion, payload: Data, tombstone: WorkspaceTransferTombstone? = nil
    ) {
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.tombstone = tombstone
    }
}

public enum WorkspaceTransferLimits {
    public static let maximumBytes = CSVImportLimits.maximumImportBytes
    public static let maximumRows = CSVImportLimits.maximumRowsTotal
    public static let maximumRowBytes = CSVImportLimits.maximumRowBytes
}

/// Transfer staging is intentionally smaller than the archive row limit. A
/// batch is an atomic, resumable unit at the authority boundary.
public enum WorkspaceTransferStagingLimits {
    public static let maximumMembersPerBatch = 200
}

public enum WorkspaceTransferStagingError: Error, Equatable, Sendable {
    case invalidBatchSize
    case invalidMember
    case invalidCheckpoint
}

/// A domain-separated SHA-256 commitment helper for resumable transfer state.
/// Length prefixes make the commitment unambiguous even when values contain
/// separators or arbitrary canonical payload bytes.
