import Foundation
import NetworkModel

/// Tombstoned, non-projecting provenance for an immutable imported audit that
/// names a source-only control record. The marker never makes that source
/// record live in the target workspace; it only preserves a bounded historical
/// reference with the exact audits that require it.
public struct ImportedHistoricalReferenceRecord: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let sourceWorkspaceID: ObjectID
    public let sourceContainerIdentifier: String
    public let sourceZoneName: String
    public let sourceZoneOwnerRecordName: String
    public let auditEventIDs: [ObjectID]
    public let recordedAt: Date

    public init(
        resourceKey: ResourceKey, sourceWorkspaceID: ObjectID, sourceContainerIdentifier: String,
        sourceZoneName: String, sourceZoneOwnerRecordName: String, auditEventIDs: [ObjectID], recordedAt: Date
    ) {
        self.resourceKey = resourceKey
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceContainerIdentifier = sourceContainerIdentifier
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerRecordName = sourceZoneOwnerRecordName
        self.auditEventIDs = auditEventIDs.sorted()
        self.recordedAt = recordedAt
    }
}
