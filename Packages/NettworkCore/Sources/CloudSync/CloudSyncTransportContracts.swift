import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum CloudSaveResult: Codable, Hashable, Sendable {
    case accepted(receipt: OperationReceipt)
    case conflict(ReconciliationCase)
    case retryableFailure(SyncFailure)
    case permanentFailure(SyncFailure)
}

public struct CloudTransportFailure: Error, Codable, Hashable, Sendable {
    public let failure: SyncFailure
    /// True only if the transport cannot determine whether its atomic request reached CloudKit.
    public let possiblyCommitted: Bool
    public init(_ failure: SyncFailure, possiblyCommitted: Bool = false) {
        self.failure = failure
        self.possiblyCommitted = possiblyCommitted
    }
}

/// CloudKit-facing boundary. A production implementation owns CKSyncEngine state
/// and uses one same-zone atomic operation with conditional record saves.
public protocol CloudRecordTransport: Sendable {
    func fetchChanges() async throws -> CloudChangeBatch
    func saveAtomically(_ mutation: AtomicCloudMutation) async throws -> CloudSaveResult
}

/// CKSyncEngine state is durable only after the mirror commits its complete
/// batch. Production transports implement this optional capability; generic
/// fake transports do not need to retain engine state.
public protocol CloudAppliedChangeStatePersisting: Sendable {
    func persistAppliedChangeState(_ state: Data) async throws
}

/// Receipt lookup resolves an indeterminate response before a retry can create a duplicate effect.
public protocol CloudReceiptLookupTransport: Sendable {
    func receipt(operationID: ObjectID, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> OperationReceipt?
}

/// Exact server-returned record state. Callers use this to bind a reservation
/// acknowledgement to the payload and conditional metadata CloudKit actually
/// persisted, never to metadata supplied by presentation code.
public struct CloudExactRecordSnapshot: Codable, Hashable, Sendable {
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let resourceKey: ResourceKey
    public let recordType: String
    public let schemaVersion: Int
    public let payload: Data
    public let exactPrecondition: ExactRecordPrecondition
    public let serverModifiedAt: Date

    public init(
        workspaceZone: AuthoritativeWorkspaceZone, resourceKey: ResourceKey, recordType: String,
        schemaVersion: Int, payload: Data, exactPrecondition: ExactRecordPrecondition, serverModifiedAt: Date
    ) {
        self.workspaceZone = workspaceZone
        self.resourceKey = resourceKey
        self.recordType = recordType
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.exactPrecondition = exactPrecondition
        self.serverModifiedAt = serverModifiedAt
    }
}

public protocol CloudExactRecordReading: Sendable {
    func exactRecord(
        for resourceKey: ResourceKey, in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot?
}

/// Organization-approved, bounded maintenance policy. There is deliberately
/// no product default: absence of a policy disables staged-transfer cleanup.
public struct CloudStagedTransferGCPolicy: Codable, Hashable, Sendable {
    public let minimumAge: TimeInterval
    public let maximumCandidates: Int
    public let maximumPagesPerCandidate: Int

    public init(minimumAge: TimeInterval, maximumCandidates: Int, maximumPagesPerCandidate: Int) throws {
        guard minimumAge.isFinite, minimumAge > 0, (1...100).contains(maximumCandidates),
            (1...100).contains(maximumPagesPerCandidate)
        else {
            throw CloudStagedTransferGCError.invalidPolicy
        }
        self.minimumAge = minimumAge
        self.maximumCandidates = maximumCandidates
        self.maximumPagesPerCandidate = maximumPagesPerCandidate
    }
}

public enum CloudStagedTransferGCError: Error, Hashable, Sendable {
    case invalidPolicy
    case malformedCandidate
    case protectedTransfer
    case staleCandidate
    case invalidMember
    case pageLimitExceeded
}

/// A query result remains coupled to server system fields for deletion
/// preflight. They are defense-in-depth rather than a hostile-client delete
/// CAS; the official-client atomic session/sentinel fence is authoritative.
/// Resource keys remain verified Cloud scalars because arbitrary member
/// records need not be decoded locally.
public struct CloudStagedTransferGCMember: Hashable, Sendable {
    public let recordName: String
    public let resourceKeyDescription: String
    public let recordType: String
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let workspaceID: ObjectID
    public let visibility: WorkspaceRecordVisibility
    public let stagedTransferID: ObjectID
    public let exactPrecondition: ExactRecordPrecondition

    public init(
        recordName: String, resourceKeyDescription: String, recordType: String, workspaceZone: AuthoritativeWorkspaceZone, workspaceID: ObjectID,
        visibility: WorkspaceRecordVisibility, stagedTransferID: ObjectID,
        exactPrecondition: ExactRecordPrecondition
    ) {
        self.recordName = recordName
        self.resourceKeyDescription = resourceKeyDescription
        self.recordType = recordType
        self.workspaceZone = workspaceZone
        self.workspaceID = workspaceID
        self.visibility = visibility
        self.stagedTransferID = stagedTransferID
        self.exactPrecondition = exactPrecondition
    }
}

/// `isComplete` is false whenever the transport has an unconsumed cursor,
/// reached its bound, or did not inspect every eligible record type. An empty
/// incomplete page is never authority to delete the transfer session.
public struct CloudStagedTransferGCMemberPage: Hashable, Sendable {
    public let members: [CloudStagedTransferGCMember]
    public let isComplete: Bool

    public init(members: [CloudStagedTransferGCMember], isComplete: Bool) {
        self.members = members
        self.isComplete = isComplete
    }
}

public struct CloudStagedTransferGCMutation: Sendable {
    public let operationID: ObjectID
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let records: [CloudRecordEnvelope]
    public let preconditions: [CloudRecordPrecondition]
    public let recordNamesToDelete: [String]
    /// Defense-in-depth preflight tags for record-ID deletes. CloudKit does
    /// not offer per-delete CAS here: member deletion is atomically fenced by
    /// the exact abandoned-session and empty-sentinel assertion saves. This
    /// relies on OfficialClientPolicy (BLK-006), not hostile-client exactness.
    public let deletionPreconditions: [String: ExactRecordPrecondition]

    public init(
        operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, records: [CloudRecordEnvelope], preconditions: [CloudRecordPrecondition],
        recordNamesToDelete: [String],
        deletionPreconditions: [String: ExactRecordPrecondition]
    ) {
        self.operationID = operationID
        self.workspaceZone = workspaceZone
        self.records = records
        self.preconditions = preconditions
        self.recordNamesToDelete = recordNamesToDelete
        self.deletionPreconditions = deletionPreconditions
    }
}

public enum CloudStagedTransferGCResult: Sendable, Hashable {
    case accepted
    case conflict
    case retryable(SyncFailure)
    case permanent(SyncFailure)
    case indeterminate(SyncFailure)
}

/// Narrow maintenance boundary. Its pages are exact server observations, not
/// local mirror inventory, and deletes remain atomic with sentinel assertions.
public protocol CloudStagedTransferGCTransport: CloudExactRecordReading {
    func stagedTransferSessions(olderThan: Date, limit: Int, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> [CloudExactRecordSnapshot]
    func stagedTransferMembers(transferID: ObjectID, limit: Int, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudStagedTransferGCMemberPage
    func applyStagedTransferGC(_ mutation: CloudStagedTransferGCMutation) async throws -> CloudStagedTransferGCResult
}

/// The app supplies a fresh foreground-membership check for every destructive
/// maintenance write. CloudKit account permission alone is not authority for a
/// detached maintenance task after session rotation or revocation.
public protocol CloudStagedTransferGCAuthorizing: Sendable {
    func authorizeStagedTransferGC(in workspaceZone: AuthoritativeWorkspaceZone) async throws
}

public struct CloudAccountIdentity: Codable, Hashable, Sendable {
    public let cloudKitUserRecordName: String
    public let isAvailable: Bool
    public init(cloudKitUserRecordName: String, isAvailable: Bool) {
        self.cloudKitUserRecordName = cloudKitUserRecordName
        self.isAvailable = isAvailable
    }
}

public enum CloudMembershipState: String, Codable, Hashable, Sendable { case owner, participant, revoked, unavailable }

/// Account and share calls are deliberately separate from record transport so a
/// fake transport cannot accidentally claim that a CloudKit account was verified.
public protocol CloudWorkspaceAuthority: Sendable {
    func currentAccount() async throws -> CloudAccountIdentity
    func createWorkspace(workspaceID: ObjectID, containerIdentifier: String) async throws -> AccountContext
    /// Owner-only operation that creates or updates the single zone-wide share.
    func inviteParticipant(owner: AccountContext, participantCloudKitUserRecordName: String, permission: WorkspaceSharePermission) async throws -> Data
    func acceptShare(metadata: Data) async throws -> AccountContext
    func revokeShare(owner: AccountContext, shareRecordName: String) async throws
    /// Returns a freshly verified context, or `nil` after revocation/unavailability.
    func verifyMembership(for context: AccountContext) async throws -> AccountContext?
}

public protocol CloudScopedStore: Sendable {
    func open(namespace: PersistenceNamespace) async throws
    func close(namespace: PersistenceNamespace) async
    func purgeEphemeralState() async
}

/// A verified batch is visible only after this one local transaction completes.
public protocol CloudMirrorStore: CloudScopedStore {
    /// Checks cross-record references and domain invariants against the scoped
    /// mirror before the transaction makes this remote batch visible.
    func validateRemoteReferences(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws
    func applyVerifiedBatch(_ records: [VerifiedCloudRecord], syncState: Data, namespace: PersistenceNamespace) async throws
    func quarantine(_ record: QuarantinedCloudRecord, namespace: PersistenceNamespace) async throws
    func syncStatus(namespace: PersistenceNamespace) async throws -> CloudMirrorStatus
}

public struct CloudMirrorStatus: Codable, Hashable, Sendable {
    public var queueDepth: Int
    public var oldestQueuedAt: Date?
    public var quarantineCount: Int
    public var conflictCount: Int
    public var lastSuccessfulServerContact: Date?
    public init(queueDepth: Int = 0, oldestQueuedAt: Date? = nil, quarantineCount: Int = 0, conflictCount: Int = 0, lastSuccessfulServerContact: Date? = nil) {
        self.queueDepth = queueDepth
        self.oldestQueuedAt = oldestQueuedAt
        self.quarantineCount = quarantineCount
        self.conflictCount = conflictCount
        self.lastSuccessfulServerContact = lastSuccessfulServerContact
    }
}

/// A placeholder coordinator that makes no CloudKit calls; root composition must
/// replace it only after a workspace account and membership are verified.
public actor UnconfiguredSyncCoordinator: SyncCoordinator {
    public init() {}
    public func synchronizeForeground() async -> SyncReceipt { SyncReceipt(errors: ["Cloud sync transport is not configured."]) }
}
