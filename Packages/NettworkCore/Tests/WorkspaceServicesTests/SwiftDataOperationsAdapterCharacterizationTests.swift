import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the operations adapter: audit and health reads come from the scoped
/// mirror, and every privileged command is delegated to the mutation
/// authority in the adapter's own account namespace.
@MainActor
final class SwiftDataOperationsAdapterCharacterizationTests: XCTestCase {
    func testAuditEventsAreNewestFirstFilteredAndNamespaceScoped() async throws {
        let fixture = try await OperationsFixture.make()

        let all = try await fixture.adapter.auditEvents(matching: "  ")
        let filtered = try await fixture.adapter.auditEvents(matching: "chg-1")

        XCTAssertEqual(all.map(\.event.id), [fixture.newer.id, fixture.older.id])
        XCTAssertEqual(filtered.map(\.event.id), [fixture.older.id])
    }

    func testCommandsAreDelegatedInTheAccountNamespace() async throws {
        let fixture = try await OperationsFixture.make()
        let presentation = ServiceFixture.presentation(for: ServiceFixture.actor(for: fixture.account))

        _ = try await fixture.adapter.validateDraft(WorkOrderDraft(title: "Draft"), authorization: presentation)
        try await fixture.adapter.requestApproval(for: ObjectID(), authorization: presentation)
        let corrective = try await fixture.adapter.createCorrectiveWorkOrder(for: ObjectID(), authorization: presentation)
        _ = await fixture.adapter.synchronizeForeground()

        XCTAssertEqual(fixture.authority.calls.map(\.name), ["validateDraft", "requestApproval", "createCorrectiveWorkOrder"])
        XCTAssertEqual(Set(fixture.authority.calls.map(\.namespace)), [fixture.account.namespace])
        XCTAssertEqual(corrective, fixture.authority.stagedID)
        let synchronized = await fixture.synchronizer.namespaces
        XCTAssertEqual(synchronized, [fixture.account.namespace])
    }

    func testAuditExportRequiresAnAuthorizationForTheCurrentAccount() async throws {
        let fixture = try await OperationsFixture.make()
        let foreignAccount = ServiceFixture.account(ServiceFixture.namespace(owner: "other-owner"))
        let foreign = AuthorizedOperationContext(
            operationID: ObjectID(), account: foreignAccount, actor: ServiceFixture.actor(for: foreignAccount), action: .exportAudit)
        let current = AuthorizedOperationContext(
            operationID: ObjectID(), account: fixture.account, actor: ServiceFixture.actor(for: fixture.account), action: .exportAudit)

        let error = await assertThrowsAny { try await fixture.adapter.exportImmutableAudit(authorization: foreign) }
        guard case ProductionAdapterError.invalidExportAuthorization? = error else {
            return XCTFail("Expected invalidExportAuthorization, got \(String(describing: error))")
        }
        XCTAssertTrue(fixture.authority.calls.isEmpty)
        _ = try await fixture.adapter.exportImmutableAudit(authorization: current)
        XCTAssertEqual(fixture.authority.calls.map(\.name), ["exportImmutableAudit"])
    }

    func testSyncHealthReportsAMirrorWithoutServerContactAsNotFresh() async throws {
        let fixture = try await OperationsFixture.make()

        let health = try await fixture.adapter.syncHealth()

        XCTAssertFalse(health.accountFresh)
        XCTAssertEqual(health.mirror.conflictCount, 0)
        XCTAssertNil(health.mirror.lastSuccessfulServerContact)
    }
}

actor RecordingSynchronizer: ProductionForegroundSynchronizing {
    private(set) var namespaces: [PersistenceNamespace] = []

    func synchronizeForeground(in namespace: PersistenceNamespace) async -> SyncReceipt {
        namespaces.append(namespace)
        return SyncReceipt()
    }
}

@MainActor
struct UnusedWorkspaceAccessReader: ProductionWorkspaceAccessReading {
    func workspaceAccess(in _: PersistenceNamespace) async throws -> WorkspaceAccessPresentation {
        throw ServiceTestError(reason: "not used")
    }
}

@MainActor
struct OperationsFixture {
    let account: AccountContext
    let older: AuditEvent
    let newer: AuditEvent
    let authority: RecordingMutationAuthority
    let synchronizer: RecordingSynchronizer
    let adapter: SwiftDataOperationsAdapter

    static func make() async throws -> OperationsFixture {
        let store = try ServiceFixture.makeStore()
        let namespace = ServiceFixture.namespace()
        let foreignNamespace = ServiceFixture.namespace(owner: "other-owner")
        try await ServiceFixture.seed(
            store, namespace: foreignNamespace, records: [try ServiceFixture.auditRecord(ServiceFixture.auditEvent(ticket: "CHG-1", at: 30), foreignNamespace)])
        let older = ServiceFixture.auditEvent(ticket: "CHG-1", at: 10)
        let newer = ServiceFixture.auditEvent(ticket: "CHG-2", at: 20)
        try await ServiceFixture.seed(
            store, namespace: namespace, records: [try ServiceFixture.auditRecord(older, namespace), try ServiceFixture.auditRecord(newer, namespace)])
        let account = ServiceFixture.account(namespace)
        let authority = RecordingMutationAuthority()
        let synchronizer = RecordingSynchronizer()
        let adapter = SwiftDataOperationsAdapter(
            account: account, persistence: store, reader: SwiftDataMirrorRecordEnumerator(persistence: store), mutations: authority,
            synchronizer: synchronizer, workspaceAccessReader: UnusedWorkspaceAccessReader(),
            telemetryExternalSignalProvider: UnavailablePrivacySafeSyncTelemetryExternalSignalProvider(),
            operationBoundary: try ServiceFixture.operationBoundary())
        return OperationsFixture(account: account, older: older, newer: newer, authority: authority, synchronizer: synchronizer, adapter: adapter)
    }
}
