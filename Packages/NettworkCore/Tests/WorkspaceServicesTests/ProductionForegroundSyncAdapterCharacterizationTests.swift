import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the foreground synchronization adapter (ARCHITECTURE.md "Foreground
/// synchronization"): membership is verified before any remote fetch, a
/// request for another workspace is refused without contacting CloudKit, and
/// each run emits privacy-safe aggregate telemetry for the synchronize step
/// and its derived health signals.
final class ProductionForegroundSyncAdapterCharacterizationTests: XCTestCase {
    func testAnotherWorkspaceIsRefusedWithoutContactingCloudKit() async throws {
        let fixture = try await ForegroundSyncFixture.make()

        let receipt = await fixture.adapter.synchronizeForeground(in: ServiceFixture.namespace())

        XCTAssertEqual(receipt.failures.map(\.category), [.security])
        let fetches = await fixture.transport.fetchCount
        XCTAssertEqual(fetches, 0)
        let synchronize = fixture.telemetry.events.filter { $0.operation == .synchronize }
        XCTAssertEqual(synchronize.map(\.outcome), [.started, .failed])
        XCTAssertEqual(synchronize.last?.failureCategory, .security)
    }

    func testVerifiedSessionFetchesAppliesAndReportsSuccess() async throws {
        let fixture = try await ForegroundSyncFixture.make()

        let receipt = await fixture.adapter.synchronizeForeground()

        XCTAssertEqual(receipt.failures, [])
        let fetches = await fixture.transport.fetchCount
        let applied = await fixture.mirror.appliedBatchCount
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(
            fixture.telemetry.events.map(\.operation),
            [.synchronize, .synchronize, .outboxReplay, .conflictHandling, .quarantine, .quotaHealth, .backupHealth])
        XCTAssertEqual(fixture.telemetry.events.prefix(2).map(\.outcome), [.started, .succeeded])
    }

    func testRevokedMembershipFailsBeforeAnyRemoteFetch() async throws {
        let fixture = try await ForegroundSyncFixture.make()
        await fixture.session.workspaceAuthority.setMembership(nil)

        let receipt = await fixture.adapter.synchronizeForeground(in: fixture.session.namespace)

        XCTAssertFalse(receipt.failures.isEmpty)
        let fetches = await fixture.transport.fetchCount
        let applied = await fixture.mirror.appliedBatchCount
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(fixture.telemetry.events.filter { $0.operation == .synchronize }.last?.outcome, .failed)
    }
}

actor EmptyChangeTransport: CloudRecordTransport {
    private(set) var fetchCount = 0

    func fetchChanges() async throws -> CloudChangeBatch {
        fetchCount += 1
        return CloudChangeBatch(records: [], newState: Data("state".utf8))
    }

    func saveAtomically(_: AtomicCloudMutation) async throws -> CloudSaveResult {
        throw ServiceTestError(reason: "no outbox work is expected")
    }
}

actor CountingMirror: CloudMirrorStore {
    private(set) var appliedBatchCount = 0

    func open(namespace _: PersistenceNamespace) async throws {}
    func close(namespace _: PersistenceNamespace) async {}
    func purgeEphemeralState() async {}
    func validateRemoteReferences(_: [VerifiedCloudRecord], namespace _: PersistenceNamespace) async throws {}
    func applyVerifiedBatch(_: [VerifiedCloudRecord], syncState _: Data, namespace _: PersistenceNamespace) async throws { appliedBatchCount += 1 }
    func quarantine(_: QuarantinedCloudRecord, namespace _: PersistenceNamespace) async throws {}
    func syncStatus(namespace _: PersistenceNamespace) async throws -> CloudMirrorStatus { CloudMirrorStatus() }
}

struct UnusedMutationState: AuthoritativeMutationStateProviding {
    func state(for _: AuthoritativeMutation) async throws -> AuthoritativeMutationState { throw ServiceTestError(reason: "not used") }
}

final class RecordingSyncTelemetry: PrivacySafeSyncTelemetryEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PrivacySafeSyncTelemetryEvent] = []

    var events: [PrivacySafeSyncTelemetryEvent] { lock.withLock { recorded } }

    func emit(_ event: PrivacySafeSyncTelemetryEvent, retention _: SyncTelemetryRetentionPolicy) {
        lock.withLock { recorded.append(event) }
    }
}

struct ForegroundSyncFixture {
    let session: SessionHarness
    let transport: EmptyChangeTransport
    let mirror: CountingMirror
    let telemetry: RecordingSyncTelemetry
    let adapter: ProductionForegroundSyncAdapter

    static func make() async throws -> ForegroundSyncFixture {
        let session = try await SessionHarness.make()
        let store = try ServiceFixture.makeStore()
        _ = await store.activateLease(for: session.namespace)
        let transport = EmptyChangeTransport()
        let mirror = CountingMirror()
        let coordinator = CloudForegroundSyncCoordinator(
            session: session.lifecycle, transport: transport, mirror: mirror, membershipVerifier: session.authorizer,
            outboxReplayer: CloudOutboxReplayer(transport: transport, outbox: store, conflicts: store), actorContextProvider: session.actors,
            mutationStateProvider: UnusedMutationState())
        let telemetry = RecordingSyncTelemetry()
        let adapter = ProductionForegroundSyncAdapter(
            account: session.account, coordinator: coordinator, telemetry: telemetry,
            retention: SyncTelemetryRetentionPolicy(maximumEventAgeSeconds: 86_400, maximumEventCount: 100),
            operationBoundary: try ServiceFixture.operationBoundary())
        return ForegroundSyncFixture(session: session, transport: transport, mirror: mirror, telemetry: telemetry, adapter: adapter)
    }
}
