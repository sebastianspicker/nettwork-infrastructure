import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Validates the final authority handoff without introducing a second write
/// path. The application constructs the normal audit/receipt activation; this
/// contract binds its workspace transition to an unchanged complete session.
public enum CloudStagedTransferFinalActivationContract {
    public static func validate(_ mutation: AuthoritativeActivationMutation) throws {
        let sessionAssertions = mutation.readAssertions.filter { $0.recordType == CloudStagedTransferRecordType.session }
        guard sessionAssertions.count <= 1 else { throw CloudStagedTransferError.lifecycleConflict }
        guard let assertion = sessionAssertions.first else { return }
        let session = try CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: assertion.encodedRecord)
        guard session.status == .complete,
            session.cursor == session.expectedMemberCount,
            session.rollingDigest == session.expectedRollingDigest
        else { throw CloudStagedTransferError.incompleteTransfer }
        guard assertion.resourceKey == session.resourceKey else { throw CloudStagedTransferError.lifecycleConflict }
        let sentinel = mutation.bootstrapSentinelResourceKey
        guard let save = mutation.saves.first(where: { $0.resourceKey == sentinel && $0.recordType == CloudRecordNaming.workspaceRecordType }),
            let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: save.encodedRecord),
            workspace.workspaceID == mutation.workspaceZone.workspaceID,
            case let .active(commit) = workspace.lifecycle,
            commit.transferID == session.transferID,
            commit.memberCount == session.cursor,
            commit.rollingDigest == session.rollingDigest,
            hasExactSentinelPrecondition(in: mutation, sentinel: sentinel)
        else { throw CloudStagedTransferError.lifecycleConflict }
    }

    private static func hasExactSentinelPrecondition(
        in mutation: AuthoritativeActivationMutation, sentinel: ResourceKey
    ) -> Bool {
        mutation.preconditions.contains { precondition in
            guard precondition.resourceKey == sentinel else { return false }
            if case .exactSystemFields = precondition { return true }
            return false
        }
    }
}
