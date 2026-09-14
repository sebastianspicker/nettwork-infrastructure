import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudSessionLifecycleTests: XCTestCase {
    func testSameScopeMembershipRefreshKeepsLeaseAndOpenStore() async throws {
        let fixture = SessionFixture()
        let store = SessionStoreSpy()
        let lifecycle = CloudSessionLifecycle(store: store)
        _ = try await lifecycle.activate(fixture.account)
        let originalLeaseValue = await lifecycle.activeLease()
        let originalLease = try XCTUnwrap(originalLeaseValue)
        let authority = SessionWorkspaceAuthority(account: fixture.account)

        let event = try await lifecycle.verifyForegroundMembership(using: authority)

        guard case let .activated(refreshed) = event else {
            return XCTFail("Expected an activated same-scope session")
        }
        let refreshedLease = await lifecycle.activeLease()
        let openCount = await store.openCount
        let closeCount = await store.closeCount
        let purgeCount = await store.purgeCount
        XCTAssertEqual(refreshed.namespace, fixture.account.namespace)
        XCTAssertEqual(refreshedLease, originalLease)
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(purgeCount, 1)
    }

    func testPermissionChangeRotatesLeaseAndRevocationInvalidates() async throws {
        let fixture = SessionFixture()
        let store = SessionStoreSpy()
        let lifecycle = CloudSessionLifecycle(store: store)
        _ = try await lifecycle.activate(fixture.account)
        let originalLeaseValue = await lifecycle.activeLease()
        let originalLease = try XCTUnwrap(originalLeaseValue)
        let downgraded = AccountContext(
            namespace: fixture.account.namespace,
            databaseScope: fixture.account.databaseScope,
            sharePermission: .readOnly,
            shareRecordName: "share-1",
            verifiedAt: .now
        )

        _ = try await lifecycle.verifyForegroundMembership(
            using: SessionWorkspaceAuthority(account: downgraded)
        )
        let downgradedLeaseValue = await lifecycle.activeLease()
        let downgradedLease = try XCTUnwrap(downgradedLeaseValue)
        let closeCount = await store.closeCount
        XCTAssertNotEqual(downgradedLease, originalLease)
        XCTAssertEqual(closeCount, 1)

        let event = try await lifecycle.verifyForegroundMembership(
            using: SessionWorkspaceAuthority(account: nil, identityRecordName: "owner-record")
        )
        let activeContext = await lifecycle.activeContext()
        let activeLease = await lifecycle.activeLease()
        XCTAssertEqual(event, .revoked)
        XCTAssertNil(activeContext)
        XCTAssertNil(activeLease)
    }
}

private struct SessionFixture {
    let account = AccountContext(
        namespace: PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "owner-record",
            workspaceID: ObjectID(),
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "owner-record",
            sessionGeneration: 1
        ),
        databaseScope: .ownerPrivate,
        sharePermission: .owner,
        verifiedAt: .now
    )
}

private actor SessionStoreSpy: CloudScopedStore {
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var purgeCount = 0

    func open(namespace: PersistenceNamespace) async throws { openCount += 1 }
    func close(namespace: PersistenceNamespace) async { closeCount += 1 }
    func purgeEphemeralState() async { purgeCount += 1 }
}

private actor SessionWorkspaceAuthority: CloudWorkspaceAuthority {
    let account: AccountContext?
    let identityRecordName: String

    init(account: AccountContext?, identityRecordName: String? = nil) {
        self.account = account
        self.identityRecordName = identityRecordName ?? account?.namespace.cloudKitAccountRecordName ?? "owner-record"
    }

    func currentAccount() async throws -> CloudAccountIdentity {
        CloudAccountIdentity(cloudKitUserRecordName: identityRecordName, isAvailable: true)
    }
    func verifyMembership(for context: AccountContext) async throws -> AccountContext? { account }
    func createWorkspace(workspaceID: ObjectID, containerIdentifier: String) async throws -> AccountContext { throw StubError.unsupported }
    func inviteParticipant(owner: AccountContext, participantCloudKitUserRecordName: String, permission: WorkspaceSharePermission) async throws -> Data {
        throw StubError.unsupported
    }
    func acceptShare(metadata: Data) async throws -> AccountContext { throw StubError.unsupported }
    func revokeShare(owner: AccountContext, shareRecordName: String) async throws { throw StubError.unsupported }

    private enum StubError: Error { case unsupported }
}
