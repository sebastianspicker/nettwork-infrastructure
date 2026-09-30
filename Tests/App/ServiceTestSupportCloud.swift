import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

struct ServiceTestError: Error, Equatable {
    let reason: String
}

/// In-memory stand-in for the authoritative CloudKit zone. Accepted mutations
/// are applied like the server would (saves replace, tombstones delete, the
/// work order is written) with a fresh change tag, so a later exact read
/// observes the committed state.
actor FakeCloudServer: CloudExactRecordReading, AuthoritativeMutationRepository {
    private var records: [ResourceKey: CloudExactRecordSnapshot] = [:]
    private var revision = 0
    private(set) var committed: [AuthoritativeMutation] = []
    private(set) var readKeys: [ResourceKey] = []
    private var commitFailure: ServiceTestError?

    func put(_ snapshot: CloudExactRecordSnapshot) { records[snapshot.resourceKey] = snapshot }

    func failCommits(with error: ServiceTestError?) { commitFailure = error }

    func snapshot(for key: ResourceKey) -> CloudExactRecordSnapshot? { records[key] }

    func exactRecord(for resourceKey: ResourceKey, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudExactRecordSnapshot? {
        readKeys.append(resourceKey)
        guard let snapshot = records[resourceKey], snapshot.workspaceZone == workspaceZone else { return nil }
        return snapshot
    }

    func commit(_ mutation: AuthoritativeMutation) async throws -> OperationReceipt {
        if let commitFailure { throw commitFailure }
        committed.append(mutation)
        revision += 1
        let tag = "server-\(revision)"
        // CloudKit reports modification dates at a coarser precision than
        // `Date.now`; whole seconds keep the date exactly representable.
        let modifiedAt = Date(timeIntervalSince1970: mutation.actor.capturedAt.timeIntervalSince1970.rounded(.down))
        for save in mutation.saves {
            records[save.resourceKey] = CloudExactRecordSnapshot(
                workspaceZone: mutation.workspaceZone, resourceKey: save.resourceKey, recordType: save.recordType, schemaVersion: save.schemaVersion,
                payload: save.encodedRecord, exactPrecondition: ServiceFixture.exact(tag), serverModifiedAt: modifiedAt)
        }
        for tombstone in mutation.tombstones { records.removeValue(forKey: tombstone.resourceKey) }
        records[.object(mutation.workOrder.id)] = CloudExactRecordSnapshot(
            workspaceZone: mutation.workspaceZone, resourceKey: .object(mutation.workOrder.id), recordType: CloudRecordNaming.workOrderRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion, payload: mutation.encodedWorkOrder, exactPrecondition: ServiceFixture.exact(tag),
            serverModifiedAt: modifiedAt)
        return mutation.receipt
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
