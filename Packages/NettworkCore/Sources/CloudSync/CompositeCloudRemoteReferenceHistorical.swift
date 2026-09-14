import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension CompositeCloudRemoteReferenceValidator {
    func validateImportedHistoricalReferenceRelationships(
        candidate: [CloudRecordEnvelope],
        snapshot: CloudRemoteMirrorSnapshot, activeTransferIDs: Set<ObjectID>, namespace: PersistenceNamespace
    ) throws {
        var postState = snapshot.recordEnvelopesByResourceKey.filter { _, envelope in
            guard case let .staged(transferID) = envelope.visibility else { return true }
            return activeTransferIDs.contains(transferID)
        }
        for envelope in candidate {
            postState[envelope.resourceKey] = envelope
        }
        let audits = try postState.values
            .filter { !$0.isDeleted && $0.recordType == CloudRecordNaming.auditRecordType }.map { envelope in
                try CloudDeterministicCoding.decode(AuditEvent.self, from: envelope.payload)
            }
        for envelope in postState.values
        where
            envelope.isDeleted && envelope.recordType == CloudRecordNaming.importedHistoricalReferenceRecordType
        {
            let marker = try CloudDeterministicCoding.decode(
                ImportedHistoricalReferenceRecord.self,
                from: envelope.payload)
            guard marker.resourceKey == envelope.resourceKey,
                marker.sourceWorkspaceID != namespace.workspaceID
            else {
                throw CloudRemoteReferenceValidationError.invalidRecords(
                    resourceKeys: [envelope.resourceKey], reason: "imported historical marker scope mismatch"
                )
            }
            let referencingIDs = Set(
                audits.filter { audit in
                    var references = Set(audit.affectedResourceKeys)
                    references.formUnion(audit.affectedObjectIDs.map(ResourceKey.object))
                    references.formUnion(audit.changes.map(\.resourceKey))
                    if let workOrderID = audit.workOrderID {
                        references.insert(.object(workOrderID))
                    }
                    return references.contains(marker.resourceKey)
                }.map(\.id))
            guard referencingIDs == Set(marker.auditEventIDs) else {
                throw CloudRemoteReferenceValidationError.invalidRecords(
                    resourceKeys: [envelope.resourceKey],
                    reason: "imported historical marker audit coverage mismatch")
            }
        }
    }

    func eligibleActiveTransferIDs(
        in envelopesByKey: [ResourceKey: CloudRecordEnvelope]
    ) throws -> Set<ObjectID> {
        let envelopes = Array(envelopesByKey.values)
        var eligible = Set<ObjectID>()
        for envelope in envelopes where !envelope.isDeleted && envelope.recordType == CloudRecordNaming.workspaceRecordType {
            if let transferID = try eligibleActiveTransferID(for: envelope, in: envelopes) {
                eligible.insert(transferID)
            }
        }
        return eligible
    }

    private func eligibleActiveTransferID(
        for workspaceEnvelope: CloudRecordEnvelope, in envelopes: [CloudRecordEnvelope]
    ) throws -> ObjectID? {
        let workspace = try CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: workspaceEnvelope.payload)
        guard case let .active(commit) = workspace.lifecycle,
            let session = try completeSession(for: commit.transferID, in: envelopes),
            sessionMatchesCommit(session, commit: commit)
        else { return nil }
        let members = stagedMembers(for: commit.transferID, in: envelopes)
        guard members.count == commit.memberCount,
            rollingDigest(for: members, session: session) == commit.rollingDigest
        else { return nil }
        return commit.transferID
    }

    private func completeSession(
        for transferID: ObjectID, in envelopes: [CloudRecordEnvelope]
    ) throws -> CloudStagedTransferSession? {
        let sessions =
            try envelopes
            .filter { !$0.isDeleted && $0.recordType == CloudStagedTransferRecordType.session }
            .map { try CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: $0.payload) }
            .filter { $0.transferID == transferID }
        return sessions.count == 1 ? sessions[0] : nil
    }

    private func sessionMatchesCommit(_ session: CloudStagedTransferSession, commit: WorkspaceActivationCommit) -> Bool {
        session.status == .complete
            && session.cursor == commit.memberCount
            && session.expectedMemberCount == commit.memberCount
            && session.rollingDigest == commit.rollingDigest
            && session.expectedRollingDigest == commit.rollingDigest
    }

    private func stagedMembers(for transferID: ObjectID, in envelopes: [CloudRecordEnvelope]) -> [CloudRecordEnvelope] {
        envelopes.filter { envelope in
            guard case let .staged(candidateTransferID) = envelope.visibility else { return false }
            return candidateTransferID == transferID
        }.sorted { $0.resourceKey < $1.resourceKey }
    }

    private func rollingDigest(for members: [CloudRecordEnvelope], session: CloudStagedTransferSession) -> String {
        members.enumerated().reduce(
            CloudStagedTransferCommitment.initial(transferID: session.transferID, operationID: session.operationID)
        ) { rolling, indexedMember in
            CloudStagedTransferCommitment.append(
                previous: rolling,
                index: indexedMember.offset,
                memberDigest: CloudStagedTransferCommitment.member(indexedMember.element))
        }
    }

    struct RecordReferences: Sendable {
        var requiredLiveReferences: Set<ResourceKey> = []
        var historicalReferences: Set<ResourceKey> = []
        var deletedResourceKeys: Set<ResourceKey> = []
    }
}
