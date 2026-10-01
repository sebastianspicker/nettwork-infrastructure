import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

struct ServiceTestError: Error, Equatable {
    let reason: String
}

/// In-memory stand-in for the authoritative CloudKit zone. Accepted mutations
/// are applied like the server would (saves replace, tombstones delete, the
/// work order, audit event and receipt are written) with a fresh change tag,
/// so a later exact read observes the committed state. Precondition checking
/// is opt-in so that narrow tests can seed records loosely.
actor FakeCloudServer: CloudExactRecordReading, AuthoritativeMutationRepository {
    private var records: [ResourceKey: CloudExactRecordSnapshot] = [:]
    private var revision = 0
    private(set) var committed: [AuthoritativeMutation] = []
    private(set) var activations: [AuthoritativeActivationMutation] = []
    private(set) var readKeys: [ResourceKey] = []
    private var commitFailure: ServiceTestError?
    private var checksPreconditions = false

    func put(_ snapshot: CloudExactRecordSnapshot) { records[snapshot.resourceKey] = snapshot }

    func failCommits(with error: ServiceTestError?) { commitFailure = error }

    /// Rejects every later commit whose preconditions do not match the
    /// current zone exactly, like a CloudKit conditional save.
    func enforcePreconditions() { checksPreconditions = true }

    func snapshot(for key: ResourceKey) -> CloudExactRecordSnapshot? { records[key] }

    func requiredSnapshot(for key: ResourceKey) throws -> CloudExactRecordSnapshot {
        guard let snapshot = records[key] else { throw ServiceTestError(reason: "missing record \(key)") }
        return snapshot
    }

    func exactRecord(for resourceKey: ResourceKey, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot? {
        readKeys.append(resourceKey)
        guard let snapshot = records[resourceKey], snapshot.workspaceZone == workspaceZone else { return nil }
        return snapshot
    }

    func commit(_ mutation: AuthoritativeMutation) async throws -> OperationReceipt {
        if let commitFailure { throw commitFailure }
        try check(mutation.preconditions)
        committed.append(mutation)
        let tag = nextTag()
        // CloudKit reports modification dates at a coarser precision than
        // `Date.now`; whole seconds keep the date exactly representable.
        let modifiedAt = Date(timeIntervalSince1970: mutation.actor.capturedAt.timeIntervalSince1970.rounded(.down))
        let zone = mutation.workspaceZone
        apply(saves: mutation.saves, tombstones: mutation.tombstones, in: zone, tag: tag, at: modifiedAt)
        store(.object(mutation.workOrder.id), CloudRecordNaming.workOrderRecordType, mutation.encodedWorkOrder, in: zone, tag: tag, at: modifiedAt)
        storeEvidence(audit: mutation.auditEvent.id, mutation.encodedAuditEvent, receipt: mutation.receipt.id, mutation.encodedReceipt, in: zone, tag: tag)
        return mutation.receipt
    }

    func commit(_ mutation: AuthoritativeActivationMutation) async throws -> OperationReceipt {
        if let commitFailure { throw commitFailure }
        try check(mutation.preconditions)
        activations.append(mutation)
        let tag = nextTag()
        let modifiedAt = Date(timeIntervalSince1970: mutation.actor.capturedAt.timeIntervalSince1970.rounded(.down))
        apply(saves: mutation.saves, tombstones: mutation.tombstones, in: mutation.workspaceZone, tag: tag, at: modifiedAt)
        storeEvidence(
            audit: mutation.auditEvent.id, mutation.encodedAuditEvent, receipt: mutation.receipt.id, mutation.encodedReceipt, in: mutation.workspaceZone,
            tag: tag)
        return mutation.receipt
    }

    /// Applies one receipt-free staged-transfer batch all-or-nothing, or
    /// reports a conflict when any record-name precondition does not hold.
    func applyConditionally(_ mutation: AtomicCloudMutation) -> CloudConditionalBatchResult {
        let keys = Dictionary(mutation.records.map { ($0.recordName, $0.resourceKey) }, uniquingKeysWith: { first, _ in first })
        for precondition in mutation.preconditions {
            switch precondition {
            case let .mustNotExist(name):
                guard let key = keys[name], records[key] == nil else { return .conflict }
            case let .exact(name, systemFields, changeTag):
                guard let key = keys[name], records[key]?.exactPrecondition == ExactRecordPrecondition(systemFields: systemFields, changeTag: changeTag)
                else { return .conflict }
            }
        }
        let tag = nextTag()
        for record in mutation.records {
            store(record.resourceKey, record.recordType, record.payload, in: mutation.workspaceZone, tag: tag, version: record.schemaVersion)
        }
        return .accepted
    }

    private func nextTag() -> String {
        revision += 1
        return "server-\(revision)"
    }

    private func check(_ preconditions: [MutationPrecondition]) throws {
        guard checksPreconditions else { return }
        for precondition in preconditions {
            switch precondition {
            case let .mustNotExist(key):
                guard records[key] == nil else { throw ServiceTestError(reason: "record exists: \(key)") }
            case let .exactSystemFields(key, exact):
                guard records[key]?.exactPrecondition == exact else { throw ServiceTestError(reason: "stale precondition: \(key)") }
            }
        }
    }

    private func apply(
        saves: [AuthoritativeRecordSave], tombstones: [AuthoritativeTombstone], in zone: AuthoritativeWorkspaceZone, tag: String, at modifiedAt: Date
    ) {
        for save in saves {
            store(save.resourceKey, save.recordType, save.encodedRecord, in: zone, tag: tag, at: modifiedAt, version: save.schemaVersion)
        }
        for tombstone in tombstones { records.removeValue(forKey: tombstone.resourceKey) }
    }

    private func storeEvidence(
        audit: ObjectID, _ encodedAudit: Data, receipt: ResourceKey, _ encodedReceipt: Data, in zone: AuthoritativeWorkspaceZone, tag: String
    ) {
        store(.object(audit), CloudRecordNaming.auditRecordType, encodedAudit, in: zone, tag: tag)
        store(receipt, CloudRecordNaming.receiptRecordType, encodedReceipt, in: zone, tag: tag)
    }

    private func store(
        _ key: ResourceKey, _ recordType: String, _ payload: Data, in zone: AuthoritativeWorkspaceZone, tag: String, at modifiedAt: Date = ServiceFixture.epoch,
        version: Int = CloudRecordNaming.schemaVersion
    ) {
        records[key] = CloudExactRecordSnapshot(
            workspaceZone: zone, resourceKey: key, recordType: recordType, schemaVersion: version, payload: payload,
            exactPrecondition: ServiceFixture.exact(tag), serverModifiedAt: modifiedAt)
    }

    /// Publishes the workspace sentinel in the given lifecycle.
    func putSentinel(_ namespace: PersistenceNamespace, lifecycle: WorkspaceLifecycle, tag: String = "workspace-sentinel") throws {
        put(
            CloudExactRecordSnapshot(
                workspaceZone: namespace.workspaceZone, resourceKey: ServiceFixture.sentinelKey(namespace),
                recordType: CloudRecordNaming.workspaceRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
                payload: try CloudDeterministicCoding.encode(ServiceFixture.workspaceRecord(namespace, lifecycle: lifecycle)),
                exactPrecondition: ServiceFixture.exact(tag), serverModifiedAt: ServiceFixture.epoch))
    }
}

actor NoopScopedStore: CloudScopedStore {
    func open(namespace _: PersistenceNamespace) async throws {}
    func close(namespace _: PersistenceNamespace) async {}
    func purgeEphemeralState() async {}
}

/// Returns a configurable CloudKit account and membership verification.
actor FakeWorkspaceAuthority: CloudWorkspaceAuthority {
    private var identity: CloudAccountIdentity
    private var membership: AccountContext?

    init(identity: CloudAccountIdentity, membership: AccountContext?) {
        self.identity = identity
        self.membership = membership
    }

    func setIdentity(_ identity: CloudAccountIdentity) { self.identity = identity }
    func setMembership(_ membership: AccountContext?) { self.membership = membership }

    func currentAccount() async throws -> CloudAccountIdentity { identity }
    func verifyMembership(for _: AccountContext) async throws -> AccountContext? { membership }
    func createWorkspace(workspaceID _: ObjectID, containerIdentifier _: String) async throws -> AccountContext {
        throw ServiceTestError(reason: "unsupported")
    }
    func inviteParticipant(owner _: AccountContext, participantCloudKitUserRecordName _: String, permission _: WorkspaceSharePermission) async throws -> Data {
        throw ServiceTestError(reason: "unsupported")
    }
    func acceptShare(metadata _: Data) async throws -> AccountContext { throw ServiceTestError(reason: "unsupported") }
    func revokeShare(owner _: AccountContext, shareRecordName _: String) async throws { throw ServiceTestError(reason: "unsupported") }
}

actor FakeActorProvider: CloudForegroundActorContextProvider {
    private var actor: ActorContext

    init(actor: ActorContext) { self.actor = actor }

    func setActor(_ actor: ActorContext) { self.actor = actor }
    func actorContext(for _: AccountContext) async throws -> ActorContext { actor }
}

actor FakeInstallationSession: ProductionInstallationSessionProviding {
    private var identifier: String

    init(identifier: String) { self.identifier = identifier }

    func setIdentifier(_ identifier: String) { self.identifier = identifier }
    func sessionID(for _: ActorContext, account _: AccountContext) async throws -> String { identifier }
}

/// A fully activated Cloud session whose account, actor, installation session
/// and membership can be varied independently to exercise revalidation.
struct SessionHarness {
    let account: AccountContext
    let actor: ActorContext
    let lifecycle: CloudSessionLifecycle
    let workspaceAuthority: FakeWorkspaceAuthority
    let actors: FakeActorProvider
    let installation: FakeInstallationSession
    let authorizer: ProductionSessionAuthorizer

    var namespace: PersistenceNamespace { account.namespace }
    var presentation: OperationsAuthorization { ServiceFixture.presentation(for: actor) }

    static func make(
        namespace: PersistenceNamespace = ServiceFixture.namespace(), role: OfficialClientRole = .administrator,
        permission: WorkspaceSharePermission = .owner
    ) async throws -> SessionHarness {
        let account = ServiceFixture.account(namespace, permission: permission)
        let actor = ServiceFixture.actor(for: account, role: role)
        let lifecycle = CloudSessionLifecycle(store: NoopScopedStore())
        try await lifecycle.activate(account)
        let workspaceAuthority = FakeWorkspaceAuthority(
            identity: CloudAccountIdentity(cloudKitUserRecordName: namespace.cloudKitAccountRecordName, isAvailable: true), membership: account)
        let actors = FakeActorProvider(actor: actor)
        let installation = FakeInstallationSession(identifier: "session-1")
        let authorizer = ProductionSessionAuthorizer(
            lifecycle: lifecycle, workspaceAuthority: workspaceAuthority, actorProvider: actors, installationSession: installation)
        return SessionHarness(
            account: account, actor: actor, lifecycle: lifecycle, workspaceAuthority: workspaceAuthority, actors: actors,
            installation: installation, authorizer: authorizer)
    }

    func operationContext(_ action: AuthorizedOperationAction, actor override: ActorContext? = nil) -> AuthorizedOperationContext {
        AuthorizedOperationContext(operationID: ObjectID(), account: account, actor: override ?? actor, action: action)
    }
}

/// Asserts that `body` throws an error equal to `expected`.
func assertThrows<E: Error & Equatable, T>(
    _ expected: E, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("Expected \(expected) to be thrown", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

/// Asserts that `body` throws any error and returns it for further checks.
@discardableResult
func assertThrowsAny<T>(
    isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
) async -> Error? {
    do {
        _ = try await body()
        XCTFail("Expected an error to be thrown", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
