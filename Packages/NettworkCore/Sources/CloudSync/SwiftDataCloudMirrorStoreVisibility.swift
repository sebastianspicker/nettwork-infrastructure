import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataCloudMirrorStore {
    func stagedTransferID(_ visibility: WorkspaceRecordVisibility) -> ObjectID? {
        guard case let .staged(transferID) = visibility else { return nil }
        return transferID
    }

    /// The ordinary lifecycle path reads the one deterministic workspace row,
    /// one exact session, and at most 200 indexed member digests. It is the
    /// ordinary apply lifecycle derivation; the legacy whole-record helper is
    /// retained only for unrelated compatibility callers.
    func deriveWorkspaceVisibilityIndexed(
        applying records: [LocalMirrorRecord],
        maintenance: LocalMirrorMaintenanceBatch, namespace: PersistenceNamespace
    ) async throws -> LocalWorkspaceVisibilityState {
        guard let workspace = try await activeWorkspace(in: records, namespace: namespace) else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: 0))
        }
        guard case let .active(commit) = workspace.lifecycle else { return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: workspace.lifecycle) }
        guard let session = try await completeSession(for: commit, in: records, namespace: namespace) else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: 0))
        }
        let members = try await transferMemberDigests(commit.transferID, applying: records, maintenance: maintenance, namespace: namespace)
        guard members.count == commit.memberCount, members.count <= LocalMirrorMaintenanceLimits.maximumTransferMembers,
            rollingDigest(
                members,
                session: session) == commit.rollingDigest
        else { return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: session.epoch)) }
        return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: workspace.lifecycle)
    }

    private func activeWorkspace(in records: [LocalMirrorRecord], namespace: PersistenceNamespace) async throws -> CloudWorkspaceRecord? {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        let persisted = try await persistence.storedLocalMirrors(for: [key], in: namespace).first
        guard let record = records.first(where: { $0.resourceKey == key }) ?? persisted, !record.isTombstone, let payload = record.payload else { return nil }
        return try CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: payload)
    }

    private func completeSession(for commit: WorkspaceActivationCommit, in records: [LocalMirrorRecord], namespace: PersistenceNamespace) async throws
        -> CloudStagedTransferSession?
    {
        let key = ResourceKey.string("workspace-transfer-session:\(commit.transferID.description)")
        let persisted = try await persistence.storedLocalMirrors(for: [key], in: namespace).first
        guard let record = records.first(where: { $0.resourceKey == key }) ?? persisted, !record.isTombstone, let payload = record.payload,
            let session = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: payload)
        else { return nil }
        return sessionMatchesCommit(session, commit: commit) ? session : nil
    }

    private func sessionMatchesCommit(_ session: CloudStagedTransferSession, commit: WorkspaceActivationCommit) -> Bool {
        session.transferID == commit.transferID
            && session.status == .complete
            && session.cursor == commit.memberCount
            && session.expectedMemberCount == commit.memberCount
            && session.rollingDigest == commit.rollingDigest
            && session.expectedRollingDigest == commit.rollingDigest
            && session.cursor <= LocalMirrorMaintenanceLimits.maximumTransferMembers
    }

    private func transferMemberDigests(
        _ transferID: ObjectID, applying records: [LocalMirrorRecord], maintenance: LocalMirrorMaintenanceBatch, namespace: PersistenceNamespace
    ) async throws -> [ResourceKey: String] {
        var members = Dictionary(
            uniqueKeysWithValues: try await persistence.mirrorTransferMembers(transferID: transferID, in: namespace).map { ($0.resourceKey, $0.digest) })
        records.forEach { members.removeValue(forKey: $0.resourceKey) }
        for fact in maintenance.records where fact.transferMember?.transferID == transferID {
            if let member = fact.transferMember { members[member.resourceKey] = member.digest }
        }
        return members
    }

    private func rollingDigest(_ members: [ResourceKey: String], session: CloudStagedTransferSession) -> String {
        members.sorted { $0.key < $1.key }.enumerated().reduce(
            CloudStagedTransferCommitment.initial(transferID: session.transferID, operationID: session.operationID)
        ) { digest, value in
            CloudStagedTransferCommitment.append(previous: digest, index: value.offset, memberDigest: value.element.value)
        }
    }

    func repairMirrorMaintenanceIndexes(in namespace: PersistenceNamespace) async throws {
        // Repair-only full read: V9 has already been marked incomplete, so a
        // normal indexed validation/apply must fail rather than trust it.
        let records = try await persistence.mirrorRecordsForExplicitMaintenanceRepair(in: namespace)
        let verified = records.map { record -> VerifiedCloudRecord in
            VerifiedCloudRecord(
                envelope: CloudRecordEnvelope(
                    recordName: CloudRecordNaming.recordName(for: record.resourceKey, workspaceID: namespace.workspaceID),
                    resourceKey: record.resourceKey, workspaceID: namespace.workspaceID,
                    recordType: cloudRecordType(for: record.recordType), schemaVersion: record.schemaVersion,
                    payload: record.payload ?? Data(), visibility: record.visibility,
                    systemFields: record.systemFields ?? Data(), changeTag: record.changeTag ?? "",
                    isDeleted: record.isTombstone))
        }
        try await persistence.repairMirrorMaintenanceIndexes(
            records: records,
            maintenance: try CloudMirrorMaintenanceFactBuilder.build(for: verified),
            in: namespace
        )
    }

    func cloudRecordType(for persistedType: String) -> String {
        switch persistedType {
        case LocalRecordKind.physicalTopology: return "NettworkPhysicalTopology"
        case LocalRecordKind.workOrder: return CloudRecordNaming.workOrderRecordType
        case LocalRecordKind.auditEvent: return CloudRecordNaming.auditRecordType
        case LocalRecordKind.prefix: return "NettworkPrefix"
        default: return persistedType
        }
    }

    func persistenceRecordType(for cloudRecordType: String) -> String {
        switch cloudRecordType {
        case "NettworkPhysicalTopology": LocalRecordKind.physicalTopology
        case CloudRecordNaming.workOrderRecordType: LocalRecordKind.workOrder
        case CloudRecordNaming.auditRecordType: LocalRecordKind.auditEvent
        case "NettworkPrefix": LocalRecordKind.prefix
        default: cloudRecordType
        }
    }
}
