import CloudSync
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum ArchiveOperationalReferencePolicy {
    static func isValid(
        transfer: ValidatedWorkspaceTransfer,
        audits: [AuditEvent],
        provenance: ArchiveSourceProvenance
    ) -> Bool {
        let sourceZone = workspaceZone(for: provenance)
        let auditIDs = Set(audits.map(\.id))
        return hasConsistentDirectReferences(transfer.candidate, auditIDs: auditIDs, sourceZone: sourceZone)
            && hasConsistentHistoricalReferences(transfer.candidate.importedHistoricalReferences, audits: audits, auditIDs: auditIDs, provenance: provenance)
    }

    static func auditHistoricalResourceKeys(_ audit: AuditEvent) -> Set<ResourceKey> {
        var keys = Set(audit.affectedResourceKeys)
        keys.formUnion(audit.affectedObjectIDs.map(ResourceKey.object))
        keys.formUnion(audit.changes.map(\.resourceKey))
        if let workOrderID = audit.workOrderID { keys.insert(.object(workOrderID)) }
        return keys
    }

    private static func workspaceZone(for provenance: ArchiveSourceProvenance) -> AuthoritativeWorkspaceZone {
        AuthoritativeWorkspaceZone(
            workspaceID: provenance.workspaceID,
            containerIdentifier: provenance.containerIdentifier,
            zoneName: provenance.zoneName,
            zoneOwnerRecordName: provenance.zoneOwnerRecordName
        )
    }

    private static func hasConsistentDirectReferences(
        _ candidate: WorkspaceTransferCandidate,
        auditIDs: Set<ObjectID>,
        sourceZone: AuthoritativeWorkspaceZone
    ) -> Bool {
        candidate.operationReceipts.allSatisfy { $0.workspaceZone == sourceZone && auditIDs.contains($0.auditEventID) }
            && candidate.workOrders.allSatisfy { workOrder in
                workOrder.reservation?.acknowledgedByCloudKit.map { $0.workspaceZone == sourceZone } ?? true
            }
            && candidate.attachmentEvidenceBindings.allSatisfy { auditIDs.contains($0.auditEventID) }
            && candidate.floorPlanAssetBindings.allSatisfy { auditIDs.contains($0.auditEventID) }
    }

    private static func hasConsistentHistoricalReferences(
        _ markers: [WorkspaceImportedHistoricalReference],
        audits: [AuditEvent],
        auditIDs: Set<ObjectID>,
        provenance: ArchiveSourceProvenance
    ) -> Bool {
        markers.allSatisfy { marker in
            hasSourceMatching(marker, provenance: provenance)
                && hasCompleteAuditReferences(marker, audits: audits, auditIDs: auditIDs)
        }
    }

    private static func hasSourceMatching(
        _ marker: WorkspaceImportedHistoricalReference,
        provenance: ArchiveSourceProvenance
    ) -> Bool {
        !marker.sourceContainerIdentifier.isEmpty
            && marker.sourceWorkspaceID == provenance.workspaceID
            && marker.sourceContainerIdentifier == provenance.containerIdentifier
            && marker.sourceZoneName == provenance.zoneName
            && marker.sourceZoneOwnerRecordName == provenance.zoneOwnerRecordName
    }

    private static func hasCompleteAuditReferences(
        _ marker: WorkspaceImportedHistoricalReference,
        audits: [AuditEvent],
        auditIDs: Set<ObjectID>
    ) -> Bool {
        let markerAuditIDs = Set(marker.auditEventIDs)
        let referencingAuditIDs = Set(audits.lazy.filter { auditHistoricalResourceKeys($0).contains(marker.resourceKey) }.map(\.id))
        return markerAuditIDs.isSubset(of: auditIDs)
            && markerAuditIDs == referencingAuditIDs
            && audits.lazy.filter { markerAuditIDs.contains($0.id) }.allSatisfy { auditHistoricalResourceKeys($0).contains(marker.resourceKey) }
    }
}
