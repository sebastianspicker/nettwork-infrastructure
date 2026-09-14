import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public actor CloudStagedTransferGarbageCollector {
    /// 198 members plus exact session and sentinel assertion saves remain at
    /// the 200-item CloudKit atomic-operation ceiling.
    public static let maximumDeleteMembersPerPage = 198

    private let policy: CloudStagedTransferGCPolicy
    private let transport: any CloudStagedTransferGCTransport
    private let authorizer: any CloudStagedTransferGCAuthorizing

    public init(policy: CloudStagedTransferGCPolicy, transport: any CloudStagedTransferGCTransport, authorizer: any CloudStagedTransferGCAuthorizing) {
        self.policy = policy
        self.transport = transport
        self.authorizer = authorizer
    }

    public func collect(in workspaceZone: AuthoritativeWorkspaceZone) async throws {
        try await authorizer.authorizeStagedTransferGC(in: workspaceZone)
        let witness = try await freshServerTimeWitness(in: workspaceZone)
        let cutoff = witness.serverModifiedAt.addingTimeInterval(-policy.minimumAge)
        let candidates = try await transport.stagedTransferSessions(olderThan: cutoff, limit: policy.maximumCandidates, in: workspaceZone)
        guard candidates.count <= policy.maximumCandidates else { throw CloudStagedTransferGCError.malformedCandidate }
        for candidate in candidates.sorted(by: { $0.serverModifiedAt < $1.serverModifiedAt }) {
            try await collect(candidate, cutoff: cutoff, in: workspaceZone)
        }
    }

    private func collect(_ candidate: CloudExactRecordSnapshot, cutoff: Date, in workspaceZone: AuthoritativeWorkspaceZone) async throws {
        let session = try validatedSession(from: candidate, cutoff: cutoff, workspaceZone: workspaceZone)
        var current = candidate
        var state = session
        let sentinel = try await emptySentinel(for: state, in: workspaceZone)
        guard (try await transport.exactRecord(for: .operationReceipt(operationID: state.operationID), in: workspaceZone)) == nil else {
            throw CloudStagedTransferGCError.protectedTransfer
        }
        if state.status != .abandoned {
            current = try await abandon(state, sessionSnapshot: current, sentinel: sentinel, in: workspaceZone)
            guard let reloaded = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: current.payload), reloaded.status == .abandoned
            else {
                throw CloudStagedTransferGCError.malformedCandidate
            }
            state = reloaded
        }
        try await deleteAbandonedMembers(state, sessionSnapshot: current, in: workspaceZone)
    }

    private func validatedSession(from candidate: CloudExactRecordSnapshot, cutoff: Date, workspaceZone: AuthoritativeWorkspaceZone) throws
        -> CloudStagedTransferSession
    {
        guard hasValidCandidateMetadata(candidate, cutoff: cutoff, workspaceZone: workspaceZone),
            let session = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: candidate.payload),
            (try? CloudDeterministicCoding.encode(session)) == candidate.payload,
            session.resourceKey == candidate.resourceKey,
            isCollectable(session)
        else { throw CloudStagedTransferGCError.malformedCandidate }
        return session
    }

    private func hasValidCandidateMetadata(_ candidate: CloudExactRecordSnapshot, cutoff: Date, workspaceZone: AuthoritativeWorkspaceZone) -> Bool {
        candidate.workspaceZone == workspaceZone && candidate.recordType == CloudStagedTransferRecordType.session
            && candidate.schemaVersion == CloudRecordNaming.schemaVersion && candidate.serverModifiedAt <= cutoff
            && hasExactPrecondition(candidate.exactPrecondition)
    }

    private func hasExactPrecondition(_ precondition: ExactRecordPrecondition) -> Bool {
        !precondition.systemFields.isEmpty && !precondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isCollectable(_ session: CloudStagedTransferSession) -> Bool {
        session.status == .staging || session.status == .complete || session.status == .abandoned
    }

    private func abandon(
        _ session: CloudStagedTransferSession, sessionSnapshot: CloudExactRecordSnapshot, sentinel: CloudExactRecordSnapshot,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot {
        let abandoned = try CloudStagedTransferSession(
            transferID: session.transferID, operationID: session.operationID, epoch: session.epoch, expectedMemberCount: session.expectedMemberCount,
            expectedRollingDigest: session.expectedRollingDigest, cursor: session.cursor, rollingDigest: session.rollingDigest, status: .abandoned)
        let mutation = try gcMutation(
            operationID: operationID(transferID: session.transferID, page: -1, memberRecordNames: []),
            workspaceZone: workspaceZone, session: sessionSnapshot, sentinel: sentinel,
            replacementSession: abandoned, deleting: [])
        try await authorizer.authorizeStagedTransferGC(in: workspaceZone)
        switch try await transport.applyStagedTransferGC(mutation) {
        case .accepted, .conflict, .indeterminate:
            guard let exact = try await transport.exactRecord(for: session.resourceKey, in: workspaceZone),
                try CloudDeterministicCoding.encode(abandoned) == exact.payload,
                (try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: exact.payload)) == abandoned,
                (try await transport.exactRecord(for: .operationReceipt(operationID: session.operationID), in: workspaceZone)) == nil
            else {
                throw CloudStagedTransferGCError.malformedCandidate
            }
            _ = try await emptySentinel(for: abandoned, in: workspaceZone)
            return exact
        case let .retryable(failure), let .permanent(failure): throw CloudTransportFailure(failure, possiblyCommitted: false)
        }
    }

    private func deleteAbandonedMembers(
        _ session: CloudStagedTransferSession, sessionSnapshot: CloudExactRecordSnapshot, in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws {
        _ = sessionSnapshot
        for page in 0..<policy.maximumPagesPerCandidate {
            guard let state = try await deletionPageState(session, in: workspaceZone) else { return }
            if state.members.isEmpty, state.isComplete {
                if try await removeFinalSession(session, state: state, page: page, in: workspaceZone) { return }
            } else {
                try validate(state.members, session: session, in: workspaceZone)
                try await remove(state.members, session: session, state: state, page: page, in: workspaceZone)
            }
        }
        throw CloudStagedTransferGCError.pageLimitExceeded
    }

    private struct DeletionPageState {
        let sentinel: CloudExactRecordSnapshot
        let session: CloudExactRecordSnapshot
        let members: [CloudStagedTransferGCMember]
        let isComplete: Bool
    }

    private func deletionPageState(_ session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> DeletionPageState? {
        let sentinel = try await emptySentinel(for: session, in: workspaceZone)
        try await requireUnprotected(session, in: workspaceZone)
        let page = try await transport.stagedTransferMembers(transferID: session.transferID, limit: Self.maximumDeleteMembersPerPage, in: workspaceZone)
        guard page.members.count <= Self.maximumDeleteMembersPerPage else { throw CloudStagedTransferGCError.invalidMember }
        guard let exact = try await transport.exactRecord(for: session.resourceKey, in: workspaceZone) else {
            try await verifyRemovedSession(page, session: session, sentinel: sentinel, in: workspaceZone)
            return nil
        }
        try validateSession(exact, matches: session)
        return DeletionPageState(sentinel: sentinel, session: exact, members: page.members, isComplete: page.isComplete)
    }

    private func requireUnprotected(_ session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) async throws {
        guard try await transport.exactRecord(for: .operationReceipt(operationID: session.operationID), in: workspaceZone) == nil else {
            throw CloudStagedTransferGCError.protectedTransfer
        }
    }

    private func verifyRemovedSession(
        _ page: CloudStagedTransferGCMemberPage, session: CloudStagedTransferSession, sentinel: CloudExactRecordSnapshot,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws {
        guard page.members.isEmpty, page.isComplete else { throw CloudStagedTransferGCError.staleCandidate }
        try await requireUnprotected(session, in: workspaceZone)
        guard (try await emptySentinel(for: session, in: workspaceZone)).resourceKey == sentinel.resourceKey else {
            throw CloudStagedTransferGCError.staleCandidate
        }
    }

    private func validateSession(_ snapshot: CloudExactRecordSnapshot, matches session: CloudStagedTransferSession) throws {
        guard let state = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: snapshot.payload),
            (try? CloudDeterministicCoding.encode(state)) == snapshot.payload, state == session
        else { throw CloudStagedTransferGCError.staleCandidate }
    }

    private func removeFinalSession(_ session: CloudStagedTransferSession, state: DeletionPageState, page: Int, in workspaceZone: AuthoritativeWorkspaceZone)
        async throws -> Bool
    {
        let operation = operationID(transferID: session.transferID, page: page, memberRecordNames: [])
        let sessionName = CloudRecordNaming.recordName(for: session.resourceKey, workspaceID: workspaceZone.workspaceID)
        let mutation = CloudStagedTransferGCMutation(
            operationID: operation, workspaceZone: workspaceZone, records: [assertion(for: state.sentinel)],
            preconditions: [
                .exact(
                    recordName: sentinelRecordName(state.sentinel), systemFields: state.sentinel.exactPrecondition.systemFields,
                    changeTag: state.sentinel.exactPrecondition.changeTag)
            ],
            recordNamesToDelete: [sessionName], deletionPreconditions: [sessionName: state.session.exactPrecondition]
        )
        try await authorizer.authorizeStagedTransferGC(in: workspaceZone)
        switch try await transport.applyStagedTransferGC(mutation) {
        case .accepted: return true
        case .conflict, .indeterminate: return try await finalRemovalWasApplied(session, sentinel: state.sentinel, in: workspaceZone)
        case let .retryable(failure), let .permanent(failure): throw CloudTransportFailure(failure, possiblyCommitted: false)
        }
    }

    private func finalRemovalWasApplied(_ session: CloudStagedTransferSession, sentinel: CloudExactRecordSnapshot, in workspaceZone: AuthoritativeWorkspaceZone)
        async throws -> Bool
    {
        let remaining = try await transport.stagedTransferMembers(transferID: session.transferID, limit: Self.maximumDeleteMembersPerPage, in: workspaceZone)
        guard (try await transport.exactRecord(for: session.resourceKey, in: workspaceZone)) == nil,
            remaining.members.isEmpty, remaining.isComplete
        else { return false }
        try await requireUnprotected(session, in: workspaceZone)
        return (try await emptySentinel(for: session, in: workspaceZone)).resourceKey == sentinel.resourceKey
    }

    private func validate(_ members: [CloudStagedTransferGCMember], session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) throws {
        guard members.allSatisfy({ isValid($0, session: session, in: workspaceZone) }) else { throw CloudStagedTransferGCError.invalidMember }
    }

    private func isValid(_ member: CloudStagedTransferGCMember, session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) -> Bool {
        hasMatchingScope(member, session: session, workspaceZone: workspaceZone)
            && hasValidRecordIdentity(member, workspaceZone: workspaceZone)
            && hasExactPrecondition(member.exactPrecondition)
    }

    private func hasMatchingScope(_ member: CloudStagedTransferGCMember, session: CloudStagedTransferSession, workspaceZone: AuthoritativeWorkspaceZone) -> Bool
    {
        member.workspaceZone == workspaceZone
            && member.workspaceID == workspaceZone.workspaceID
            && member.stagedTransferID == session.transferID
            && member.visibility == .staged(transferID: session.transferID)
    }

    private func hasValidRecordIdentity(_ member: CloudStagedTransferGCMember, workspaceZone: AuthoritativeWorkspaceZone) -> Bool {
        guard CloudRecordNaming.domainRecordTypes.contains(member.recordType),
            member.recordType != CloudStagedTransferRecordType.session,
            !member.recordName.isEmpty,
            !member.resourceKeyDescription.isEmpty
        else { return false }
        return member.recordName
            == CloudRecordNaming.recordName(
                forResourceKeyDescription: member.resourceKeyDescription,
                workspaceID: workspaceZone.workspaceID)
    }

    private func remove(
        _ members: [CloudStagedTransferGCMember], session: CloudStagedTransferSession, state: DeletionPageState, page: Int,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws {
        let mutation = try gcMutation(
            operationID: operationID(transferID: session.transferID, page: page, memberRecordNames: members.map(\.recordName)), workspaceZone: workspaceZone,
            session: state.session,
            sentinel: state.sentinel, replacementSession: nil, deleting: members)
        try await authorizer.authorizeStagedTransferGC(in: workspaceZone)
        switch try await transport.applyStagedTransferGC(mutation) {
        case .accepted, .conflict, .indeterminate: return
        case let .retryable(failure), let .permanent(failure): throw CloudTransportFailure(failure, possiblyCommitted: false)
        }
    }

    /// The age cutoff is computed from this server-issued witness only. There
    /// is deliberately no local wall-clock fallback for remote eligibility.
    private func freshServerTimeWitness(in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot {
        let original = try await emptySentinel(in: workspaceZone)
        let mutation = CloudStagedTransferGCMutation(
            operationID: witnessOperationID(for: workspaceZone.workspaceID),
            workspaceZone: workspaceZone,
            records: [assertion(for: original)],
            preconditions: [
                .exact(
                    recordName: sentinelRecordName(original), systemFields: original.exactPrecondition.systemFields,
                    changeTag: original.exactPrecondition.changeTag)
            ],
            recordNamesToDelete: [],
            deletionPreconditions: [:]
        )
        try await authorizer.authorizeStagedTransferGC(in: workspaceZone)
        switch try await transport.applyStagedTransferGC(mutation) {
        case .accepted, .conflict, .indeterminate:
            let witness = try await emptySentinel(in: workspaceZone)
            guard witness.exactPrecondition != original.exactPrecondition else {
                throw CloudStagedTransferGCError.staleCandidate
            }
            return witness
        case let .retryable(failure), let .permanent(failure):
            throw CloudTransportFailure(failure, possiblyCommitted: false)
        }
    }

    private func emptySentinel(in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspaceZone.workspaceID)
        guard let sentinel = try await transport.exactRecord(for: key, in: workspaceZone),
            sentinel.workspaceZone == workspaceZone,
            sentinel.resourceKey == key,
            sentinel.recordType == CloudRecordNaming.workspaceRecordType,
            sentinel.schemaVersion == CloudRecordNaming.schemaVersion,
            !sentinel.exactPrecondition.systemFields.isEmpty,
            !sentinel.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: sentinel.payload),
            (try? CloudDeterministicCoding.encode(workspace)) == sentinel.payload,
            workspace.workspaceID == workspaceZone.workspaceID,
            case .empty = workspace.lifecycle
        else { throw CloudStagedTransferGCError.protectedTransfer }
        return sentinel
    }

    private func emptySentinel(for session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot {
        let sentinel = try await emptySentinel(in: workspaceZone)
        guard let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: sentinel.payload),
            case let .empty(epoch) = workspace.lifecycle,
            epoch == session.epoch
        else { throw CloudStagedTransferGCError.protectedTransfer }
        return sentinel
    }

    private func gcMutation(
        operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, session: CloudExactRecordSnapshot, sentinel: CloudExactRecordSnapshot,
        replacementSession: CloudStagedTransferSession?,
        deleting: [CloudStagedTransferGCMember]
    ) throws -> CloudStagedTransferGCMutation {
        let sessionRecord: CloudRecordEnvelope
        if let replacementSession {
            sessionRecord = CloudRecordEnvelope(
                resourceKey: session.resourceKey, workspaceID: workspaceZone.workspaceID, recordType: session.recordType, schemaVersion: session.schemaVersion,
                payload: try CloudDeterministicCoding.encode(replacementSession), writeMode: .businessSave, visibility: .live,
                systemFields: session.exactPrecondition.systemFields, changeTag: session.exactPrecondition.changeTag)
        } else {
            sessionRecord = assertion(for: session)
        }
        let sentinelRecord = assertion(for: sentinel)
        guard deleting.count <= Self.maximumDeleteMembersPerPage else { throw CloudStagedTransferGCError.invalidMember }
        let records = [sessionRecord, sentinelRecord]
        guard records.count + deleting.count <= AtomicCloudMutation.maximumBusinessRecordsPerOperation else { throw CloudStagedTransferGCError.invalidMember }
        let preconditions: [CloudRecordPrecondition] = records.map {
            .exact(recordName: $0.recordName, systemFields: $0.systemFields, changeTag: $0.changeTag)
        }
        return CloudStagedTransferGCMutation(
            operationID: operationID, workspaceZone: workspaceZone, records: records, preconditions: preconditions,
            recordNamesToDelete: deleting.map(\.recordName).sorted(),
            deletionPreconditions: Dictionary(uniqueKeysWithValues: deleting.map { ($0.recordName, $0.exactPrecondition) }))
    }

    private func assertion(for snapshot: CloudExactRecordSnapshot) -> CloudRecordEnvelope {
        CloudRecordEnvelope(
            resourceKey: snapshot.resourceKey, workspaceID: snapshot.workspaceZone.workspaceID, recordType: snapshot.recordType,
            schemaVersion: snapshot.schemaVersion, payload: snapshot.payload,
            writeMode: .assertionPreserving, visibility: .live, systemFields: snapshot.exactPrecondition.systemFields,
            changeTag: snapshot.exactPrecondition.changeTag)
    }

    private func sentinelRecordName(_ snapshot: CloudExactRecordSnapshot) -> String {
        CloudRecordNaming.recordName(for: snapshot.resourceKey, workspaceID: snapshot.workspaceZone.workspaceID)
    }

    private func operationID(transferID: ObjectID, page: Int, memberRecordNames: [String]) -> ObjectID {
        let pageDigest = SHA256.hash(data: Data(memberRecordNames.sorted().joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
        let hex = SHA256.hash(data: Data("nettwork.staged-transfer-gc.v1:\(transferID.description):\(page):\(pageDigest)".utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return deterministicObjectID(from: hex)
    }

    private func witnessOperationID(for workspaceID: ObjectID) -> ObjectID {
        let hex = SHA256.hash(data: Data("nettwork.staged-transfer-gc.server-time-witness.v1:\(workspaceID.description)".utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return deterministicObjectID(from: hex)
    }

    private func deterministicObjectID(from hex: String) -> ObjectID {
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("A SHA-256-derived UUID must be syntactically valid.")
        }
        return ObjectID(uuid)
    }
}
