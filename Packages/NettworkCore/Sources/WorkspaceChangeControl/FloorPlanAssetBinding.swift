import Foundation
import NetworkModel

/// Metadata committed in the planned work-order intent before the sanitized
/// floor-plan bytes are materialized. It intentionally has no staging token,
/// file URL, or source path.
public struct PlannedFloorPlanAsset: Codable, Hashable, Sendable {
    public let floorID: ObjectID
    public let assetMetadata: CloudRecordAssetMetadata

    public init(floorID: ObjectID, assetMetadata: CloudRecordAssetMetadata) throws {
        guard assetMetadata.fieldName == "floorPlanAsset",
            assetMetadata.contentType == "image/jpeg"
        else {
            throw FloorPlanAssetBindingError.invalidPlannedAsset
        }
        self.floorID = floorID
        self.assetMetadata = assetMetadata
    }
}

/// Immutable authoritative relationship between one floor, the completed work
/// order that planned its metadata, its audit/receipt operation, and the
/// record-bound CloudKit asset. The local sanitized-file lease is deliberately
/// absent: only validated bytes travelling with this record are authoritative.
public struct FloorPlanAssetBindingRecord: Codable, Hashable, Sendable {
    public let floorID: ObjectID
    public let workOrderID: ObjectID
    public let assetMetadata: CloudRecordAssetMetadata
    public let intentDigest: IntentDigest
    public let operationID: ObjectID
    public let auditEventID: ObjectID
    public let boundAt: Date

    public init(
        floorID: ObjectID, workOrderID: ObjectID, assetMetadata: CloudRecordAssetMetadata,
        intentDigest: IntentDigest, operationID: ObjectID, auditEventID: ObjectID, boundAt: Date
    ) throws {
        _ = try PlannedFloorPlanAsset(floorID: floorID, assetMetadata: assetMetadata)
        guard auditEventID == AuditEvent.deterministicID(for: operationID) else {
            throw FloorPlanAssetBindingError.invalidBinding
        }
        self.floorID = floorID
        self.workOrderID = workOrderID
        self.assetMetadata = assetMetadata
        self.intentDigest = intentDigest
        self.operationID = operationID
        self.auditEventID = auditEventID
        self.boundAt = boundAt
    }

    public var resourceKey: ResourceKey { .floorPlanAssetBinding(for: floorID) }
}

public enum FloorPlanAssetBindingError: Error, Equatable, Sendable {
    case invalidPlannedAsset
    case invalidBinding
}

public extension ResourceKey {
    static func floorPlanAssetBinding(for floorID: ObjectID) -> Self {
        .string("floor-plan-asset-binding:\(floorID.description)")
    }
}
