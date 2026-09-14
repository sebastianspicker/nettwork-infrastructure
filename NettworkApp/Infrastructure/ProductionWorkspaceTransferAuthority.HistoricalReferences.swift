import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func importedHistoricalReferenceEnvelopes(
        transfer: ValidatedWorkspaceTransfer, audits: [AuditEvent], assets: [CloudRecordEnvelope], provenance: ArchiveSourceProvenance?,
        recordedAt: Date?, namespace: PersistenceNamespace, transferID: ObjectID
    ) throws -> [CloudRecordEnvelope] {
        guard !audits.isEmpty else { return [] }
        guard let provenance, let recordedAt else {
            throw ProductionWorkspaceTransferAuthorityError.malformedArchiveAudit
        }
        var representedKeys = Set(transfer.saves.map(\.resourceKey))
        representedKeys.formUnion(transfer.tombstones.map(\.resourceKey))
        representedKeys.formUnion(assets.map { $0.resourceKey })
        representedKeys.formUnion(audits.map { .object($0.id) })
        representedKeys.insert(
            AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        )

        var auditIDsByMissingKey: [ResourceKey: Set<ObjectID>] = [:]
        for audit in audits {
            for key in auditHistoricalResourceKeys(audit) where !representedKeys.contains(key) {
                auditIDsByMissingKey[key, default: []].insert(audit.id)
            }
        }
        return try auditIDsByMissingKey.sorted { $0.key < $1.key }.map { key, auditIDs in
            let marker = WorkspaceImportedHistoricalReference(
                resourceKey: key,
                sourceWorkspaceID: provenance.workspaceID,
                sourceContainerIdentifier: provenance.containerIdentifier,
                sourceZoneName: provenance.zoneName,
                sourceZoneOwnerRecordName: provenance.zoneOwnerRecordName,
                auditEventIDs: auditIDs.sorted(),
                recordedAt: recordedAt
            )
            return CloudRecordEnvelope(
                resourceKey: key,
                workspaceID: namespace.workspaceID,
                recordType: CloudRecordNaming.importedHistoricalReferenceRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                payload: try WorkspaceTransferCoding.encode(marker),
                visibility: .staged(transferID: transferID),
                systemFields: Data(),
                changeTag: "",
                isDeleted: true
            )
        }
    }
}
