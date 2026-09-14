import CryptoKit
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// CloudSync-local transfer protocol. Import/export translates its canonical
/// plan at app composition; this target never imports presentation/archive IO.
public enum CloudStagedTransferLimits {
    public static let maximumMembersPerBatch = 200
}
public enum CloudStagedTransferError: Error, Hashable, Sendable {
    case invalidSession
    case invalidMember(ResourceKey)
    case invalidBatchSize
    case cursorConflict
    case incompleteTransfer
    case digestMismatch
    case lifecycleConflict
    case protectedAssetMissing(ResourceKey)
}
public enum CloudStagedTransferRecordType {
    public static let session = AuthoritativeActivationMutation.transferSessionRecordType
    public static let infrastructure: Set<String> = [session]
}
public enum CloudStagedTransferStatus: String, Codable, Hashable, Sendable {
    case staging, complete, abandoned
}

/// The conditional session cursor is the sole progress authority. Every
/// successful append advances both count and digest deterministically.
public struct CloudStagedTransferSession: Codable, Hashable, Sendable {
    public let transferID: ObjectID
    public let operationID: ObjectID
    public let epoch: UInt64
    public let expectedMemberCount: Int
    public let expectedRollingDigest: String
    public let cursor: Int
    public let rollingDigest: String
    public let status: CloudStagedTransferStatus

    public init(
        transferID: ObjectID, operationID: ObjectID, epoch: UInt64, expectedMemberCount: Int,
        expectedRollingDigest: String, cursor: Int = 0, rollingDigest: String? = nil,
        status: CloudStagedTransferStatus = .staging
    ) throws {
        guard expectedMemberCount >= 0, cursor >= 0, cursor <= expectedMemberCount,
            !expectedRollingDigest.isEmpty
        else { throw CloudStagedTransferError.invalidSession }
        self.transferID = transferID
        self.operationID = operationID
        self.epoch = epoch
        self.expectedMemberCount = expectedMemberCount
        self.expectedRollingDigest = expectedRollingDigest
        self.cursor = cursor
        self.rollingDigest = rollingDigest ?? CloudStagedTransferCommitment.initial(transferID: transferID, operationID: operationID)
        self.status = status
    }

    public var resourceKey: ResourceKey { .string("workspace-transfer-session:\(transferID.description)") }
}
public enum CloudStagedTransferCommitment {
    public static func initial(transferID: ObjectID, operationID: ObjectID) -> String {
        digest("nettwork.cloud-staged-transfer.initial.v1", [transferID.description, operationID.description])
    }

    public static func member(_ envelope: CloudRecordEnvelope) -> String {
        member(
            recordType: envelope.recordType, resourceKey: envelope.resourceKey,
            schemaVersion: envelope.schemaVersion, payload: envelope.payload,
            isDeleted: envelope.isDeleted, visibility: envelope.visibility,
            assetMetadata: envelope.recordAsset?.metadata)
    }

    public static func member(
        recordType: String, resourceKey: ResourceKey, schemaVersion: Int,
        payload: Data, isDeleted: Bool, visibility recordVisibility: WorkspaceRecordVisibility,
        assetMetadata: CloudRecordAssetMetadata?
    ) -> String {
        let asset = assetMetadata
        return digest(
            "nettwork.cloud-staged-transfer.member.v1",
            [
                recordType, resourceKey.description,
                String(schemaVersion), String(isDeleted), visibility(recordVisibility),
                SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                asset.map { "\($0.id.description)|\($0.fieldName)|\($0.contentType)|\($0.byteCount)|\($0.sha256)" } ?? "no-asset",
            ])
    }

    public static func append(previous: String, index: Int, memberDigest: String) -> String {
        digest("nettwork.cloud-staged-transfer.append.v1", [previous, String(index), memberDigest])
    }

    private static func digest(_ domain: String, _ fields: [String]) -> String {
        let joined = ([domain] + fields.map { "\($0.utf8.count):\($0)" }).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func visibility(_ value: WorkspaceRecordVisibility) -> String {
        switch value {
        case .live: return "live"
        case let .staged(transferID): return "staged:\(transferID.description)"
        }
    }
}
public enum CloudStagedTransferLifecycle {
    /// Session-first and workspace-final delivery are both invisible. Activation
    /// is derived only when all staged members, a complete session, and the
    /// authoritative workspace lifecycle commit agree; malformed state fails closed.
    public static func derive(
        records: [LocalMirrorRecord], namespace: PersistenceNamespace
    ) throws -> LocalWorkspaceVisibilityState {
        let live = records.filter { !$0.isTombstone }
        let workspaces = try live.filter { $0.recordType == CloudRecordNaming.workspaceRecordType }.map {
            try CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: $0.payload ?? Data())
        }
        guard workspaces.count == 1, let workspace = workspaces.first else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: 0))
        }
        guard case let .active(commit) = workspace.lifecycle else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: workspace.lifecycle)
        }
        let sessions = try live.filter { $0.recordType == CloudStagedTransferRecordType.session }.map {
            try CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: $0.payload ?? Data())
        }
        guard let session = sessions.first(where: { $0.transferID == commit.transferID }),
            session.status == .complete, session.cursor == commit.memberCount,
            session.rollingDigest == commit.rollingDigest,
            session.expectedMemberCount == commit.memberCount,
            session.expectedRollingDigest == commit.rollingDigest
        else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: sessionEpoch(workspace.lifecycle)))
        }
        let members = records.filter {
            if case let .staged(transferID) = $0.visibility { return transferID == commit.transferID }
            return false
        }.sorted { $0.resourceKey < $1.resourceKey }
        guard members.count == commit.memberCount else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: session.epoch))
        }
        var rolling = CloudStagedTransferCommitment.initial(transferID: session.transferID, operationID: session.operationID)
        for (index, member) in members.enumerated() {
            let digest = CloudStagedTransferCommitment.member(
                recordType: member.recordType, resourceKey: member.resourceKey,
                schemaVersion: member.schemaVersion, payload: member.payload ?? Data(),
                isDeleted: member.isTombstone, visibility: member.visibility,
                assetMetadata: member.recordAssetMetadata)
            rolling = CloudStagedTransferCommitment.append(previous: rolling, index: index, memberDigest: digest)
        }
        guard rolling == commit.rollingDigest else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: session.epoch))
        }
        return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: workspace.lifecycle)
    }

    private static func sessionEpoch(_ lifecycle: WorkspaceLifecycle) -> UInt64 {
        switch lifecycle {
        case let .empty(epoch): return epoch
        case .active: return 0
        }
    }
}
/// Receipt-free transport used for resumable session CAS writes. An accepted
/// result proves the bounded batch, whereas an indeterminate result must be
/// resolved by reading the deterministic session cursor before retrying.
public enum CloudConditionalBatchResult: Sendable, Hashable {
    case accepted
    case conflict
    case retryable(SyncFailure)
    case permanent(SyncFailure)
    case indeterminate(SyncFailure)
}

public protocol CloudConditionalBatchTransport: Sendable {
    func saveConditionally(_ mutation: AtomicCloudMutation) async throws -> CloudConditionalBatchResult
}

public actor CloudStagedTransferRepository {
    private let transport: any CloudConditionalBatchTransport
    private let reader: any CloudExactRecordReading

    public init(transport: any CloudConditionalBatchTransport, reader: any CloudExactRecordReading) {
        self.transport = transport
        self.reader = reader
    }

    /// Creates the deterministic session exactly once. A lost response is
    /// resolved from the server-returned session, yielding the exact CAS
    /// precondition required by the first append.
    public func begin(
        _ session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot {
        guard session.status == .staging, session.cursor == 0 else { throw CloudStagedTransferError.invalidSession }
        let envelope = try envelope(for: session, in: workspaceZone, systemFields: Data(), changeTag: "")
        let mutation = AtomicCloudMutation(
            operationID: deterministicOperationID(transferID: session.transferID, cursor: 0),
            workspaceZone: workspaceZone, records: [envelope],
            preconditions: [.mustNotExist(recordName: envelope.recordName)])
        try AtomicCloudMutationValidator.validate(mutation)
        switch try await transport.saveConditionally(mutation) {
        case .accepted, .conflict, .indeterminate:
            return try await resolvedSessionSnapshot(expected: session, in: workspaceZone)
        case let .retryable(failure), let .permanent(failure): throw CloudTransportFailure(failure)
        }
    }

    /// Read the server's current session and its exact conditional metadata.
    /// The app authority calls this after each append/complete and uses the
    /// returned payload unchanged for the final activation read assertion.
    public func exactSession(
        expected: CloudStagedTransferSession,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot {
        try await resolvedSessionSnapshot(expected: expected, in: workspaceZone)
    }

    public func append(
        _ members: [CloudRecordEnvelope], session: CloudStagedTransferSession,
        sessionPrecondition: ExactRecordPrecondition, in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudStagedTransferSession {
        try validateAppend(members, session: session)
        let sorted = members.sorted { $0.resourceKey < $1.resourceKey }
        var rolling = session.rollingDigest
        for (offset, member) in sorted.enumerated() {
            rolling = CloudStagedTransferCommitment.append(
                previous: rolling, index: session.cursor + offset, memberDigest: CloudStagedTransferCommitment.member(member))
        }
        let next = try CloudStagedTransferSession(
            transferID: session.transferID, operationID: session.operationID, epoch: session.epoch,
            expectedMemberCount: session.expectedMemberCount, expectedRollingDigest: session.expectedRollingDigest,
            cursor: session.cursor + sorted.count, rollingDigest: rolling, status: .staging)
        let sessionEnvelope = try envelope(
            for: next, in: workspaceZone, systemFields: sessionPrecondition.systemFields, changeTag: sessionPrecondition.changeTag)
        let mutation = AtomicCloudMutation(
            operationID: deterministicOperationID(transferID: session.transferID, cursor: next.cursor),
            workspaceZone: workspaceZone, records: sorted + [sessionEnvelope],
            preconditions: sorted.map { .mustNotExist(recordName: $0.recordName) } + [
                .exact(recordName: sessionEnvelope.recordName, systemFields: sessionPrecondition.systemFields, changeTag: sessionPrecondition.changeTag)
            ]
        )
        try AtomicCloudMutationValidator.validate(mutation)
        switch try await transport.saveConditionally(mutation) {
        case .accepted: return next
        case .conflict, .indeterminate: return try await resolveRetry(expected: next, in: workspaceZone)
        case let .retryable(failure): throw CloudTransportFailure(failure, possiblyCommitted: false)
        case let .permanent(failure): throw CloudTransportFailure(failure, possiblyCommitted: false)
        }
    }

    private func validateAppend(_ members: [CloudRecordEnvelope], session: CloudStagedTransferSession) throws {
        guard !members.isEmpty,
            members.count <= CloudStagedTransferLimits.maximumMembersPerBatch,
            session.status == .staging
        else { throw CloudStagedTransferError.invalidBatchSize }
        guard
            members.allSatisfy({ member in
                guard case let .staged(transferID) = member.visibility else { return false }
                return transferID == session.transferID
            })
        else {
            throw CloudStagedTransferError.invalidMember(members.first?.resourceKey ?? session.resourceKey)
        }
    }

    public func complete(
        session: CloudStagedTransferSession, sessionPrecondition: ExactRecordPrecondition,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudStagedTransferSession {
        guard session.cursor == session.expectedMemberCount,
            session.rollingDigest == session.expectedRollingDigest
        else { throw CloudStagedTransferError.incompleteTransfer }
        let complete = try CloudStagedTransferSession(
            transferID: session.transferID, operationID: session.operationID, epoch: session.epoch,
            expectedMemberCount: session.expectedMemberCount, expectedRollingDigest: session.expectedRollingDigest,
            cursor: session.cursor, rollingDigest: session.rollingDigest, status: .complete)
        let completeEnvelope = try envelope(
            for: complete, in: workspaceZone, systemFields: sessionPrecondition.systemFields, changeTag: sessionPrecondition.changeTag)
        let mutation = AtomicCloudMutation(
            operationID: deterministicOperationID(transferID: complete.transferID, cursor: complete.cursor + 1),
            workspaceZone: workspaceZone, records: [completeEnvelope],
            preconditions: [
                .exact(recordName: completeEnvelope.recordName, systemFields: sessionPrecondition.systemFields, changeTag: sessionPrecondition.changeTag)
            ]
        )
        try AtomicCloudMutationValidator.validate(mutation)
        switch try await transport.saveConditionally(mutation) {
        case .accepted: return complete
        case .conflict, .indeterminate: return try await resolveRetry(expected: complete, in: workspaceZone)
        case let .retryable(failure), let .permanent(failure): throw CloudTransportFailure(failure)
        }
    }

    public func abandon(
        session: CloudStagedTransferSession, sessionPrecondition: ExactRecordPrecondition,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudStagedTransferSession {
        let abandoned = try CloudStagedTransferSession(
            transferID: session.transferID, operationID: session.operationID, epoch: session.epoch,
            expectedMemberCount: session.expectedMemberCount, expectedRollingDigest: session.expectedRollingDigest,
            cursor: session.cursor, rollingDigest: session.rollingDigest, status: .abandoned)
        let envelope = try envelope(for: abandoned, in: workspaceZone, systemFields: sessionPrecondition.systemFields, changeTag: sessionPrecondition.changeTag)
        let mutation = AtomicCloudMutation(
            operationID: deterministicOperationID(transferID: abandoned.transferID, cursor: abandoned.cursor + 2),
            workspaceZone: workspaceZone, records: [envelope],
            preconditions: [.exact(recordName: envelope.recordName, systemFields: sessionPrecondition.systemFields, changeTag: sessionPrecondition.changeTag)]
        )
        try AtomicCloudMutationValidator.validate(mutation)
        switch try await transport.saveConditionally(mutation) {
        case .accepted: return abandoned
        case .conflict, .indeterminate: return try await resolveRetry(expected: abandoned, in: workspaceZone)
        case let .retryable(failure), let .permanent(failure): throw CloudTransportFailure(failure)
        }
    }

    private func resolveRetry(expected: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudStagedTransferSession {
        let snapshot = try await resolvedSessionSnapshot(expected: expected, in: workspaceZone)
        guard let current = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: snapshot.payload) else {
            throw CloudStagedTransferError.cursorConflict
        }
        guard current.transferID == expected.transferID, current.cursor == expected.cursor,
            current.rollingDigest == expected.rollingDigest
        else { throw CloudStagedTransferError.cursorConflict }
        return current
    }

    private func resolvedSessionSnapshot(
        expected: CloudStagedTransferSession,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot {
        guard let snapshot = try await reader.exactRecord(for: expected.resourceKey, in: workspaceZone),
            snapshot.recordType == CloudStagedTransferRecordType.session,
            let current = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: snapshot.payload),
            current.transferID == expected.transferID, current.operationID == expected.operationID,
            current.cursor == expected.cursor, current.rollingDigest == expected.rollingDigest,
            current.status == expected.status
        else {
            throw CloudStagedTransferError.cursorConflict
        }
        return snapshot
    }

    private func envelope(for session: CloudStagedTransferSession, in workspaceZone: AuthoritativeWorkspaceZone, systemFields: Data, changeTag: String) throws
        -> CloudRecordEnvelope
    {
        CloudRecordEnvelope(
            resourceKey: session.resourceKey, workspaceID: workspaceZone.workspaceID, recordType: CloudStagedTransferRecordType.session,
            payload: try CloudDeterministicCoding.encode(session),
            systemFields: systemFields, changeTag: changeTag)
    }

    private func deterministicOperationID(transferID: ObjectID, cursor: Int) -> ObjectID {
        let hex = SHA256.hash(data: Data("nettwork.cloud-staged-transfer.cas.v1:\(transferID.description):\(cursor)".utf8)).map { String(format: "%02x", $0) }
            .joined()
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("A SHA-256-derived UUID must be syntactically valid.")
        }
        return ObjectID(uuid)
    }
}
