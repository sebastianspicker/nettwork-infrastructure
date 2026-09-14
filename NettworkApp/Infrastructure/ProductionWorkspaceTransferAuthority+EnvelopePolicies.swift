import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func acceptedAuditEvent(operationID: ObjectID, actor: ActorInstallationSnapshot, sentinel: AuthoritativeRecordSave) -> AuditEvent {
        AuditEvent(
            id: AuditEvent.deterministicID(for: operationID), operationID: operationID, actorID: actor.actorID, affectedObjectIDs: [],
            occurredAt: actor.capturedAt, result: .accepted, installationID: actor.installationID, sessionID: actor.sessionID,
            sessionGeneration: actor.sessionGeneration, source: .importExport, affectedResourceKeys: [sentinel.resourceKey],
            changes: [AuditRecordChange(resourceKey: sentinel.resourceKey, after: sentinel.encodedRecord)], policyVersion: Self.activationPolicyVersion
        )
    }

    func stagedAuditEnvelopes(
        _ audits: [AuditEvent], namespace: PersistenceNamespace, visibility: WorkspaceRecordVisibility
    ) throws -> [CloudRecordEnvelope] {
        try audits.map { audit in
            CloudRecordEnvelope(
                resourceKey: .object(audit.id),
                workspaceID: namespace.workspaceID,
                recordType: CloudRecordNaming.auditRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion,
                payload: try CloudDeterministicCoding.encode(audit),
                visibility: visibility,
                systemFields: Data(),
                changeTag: ""
            )
        }
    }
}
