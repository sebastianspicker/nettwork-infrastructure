import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

final class AppCompositionTests: XCTestCase {
    @MainActor
    func testProductionBootstrapActivatesBeforeSyncAndInvalidatesOnStop() async {
        let probe = BootstrapProbe()
        let coordinator = StubSyncCoordinator(receipt: SyncReceipt(queueDepth: 2))
        let service = ProductionAppBootstrapService(
            activateWorkspace: { await probe.activate() },
            syncCoordinator: coordinator,
            invalidateWorkspace: { await probe.invalidate() }
        )
        let dependencies = AppDependencies(bootstrapService: service)

        await dependencies.bootstrap()

        XCTAssertEqual(dependencies.syncStatus, .ready)
        XCTAssertEqual(dependencies.lastSyncReceipt?.queueDepth, 2)
        let activatedEvents = await probe.events()
        XCTAssertEqual(activatedEvents, [.activated])

        await dependencies.shutdown()

        let stoppedEvents = await probe.events()
        XCTAssertEqual(stoppedEvents, [.activated, .invalidated])
        XCTAssertEqual(dependencies.syncStatus, .offline(reason: "The account-scoped workspace is closed."))
    }

    @MainActor
    func testAccountUnavailableReceiptNeverClaimsReady() async {
        let coordinator = StubSyncCoordinator(
            receipt: SyncReceipt(failures: [
                SyncFailure(category: .accountUnavailable, message: "Membership was revoked.")
            ]))
        let service = ProductionAppBootstrapService(
            activateWorkspace: {},
            syncCoordinator: coordinator,
            invalidateWorkspace: {}
        )
        let dependencies = AppDependencies(bootstrapService: service)

        await dependencies.bootstrap()

        XCTAssertEqual(dependencies.syncStatus, .offline(reason: "Membership was revoked."))
        XCTAssertNil(dependencies.lastSyncReceipt)
    }
}

private actor StubSyncCoordinator: SyncCoordinator {
    let receipt: SyncReceipt
    init(receipt: SyncReceipt) { self.receipt = receipt }
    func synchronizeForeground() async -> SyncReceipt { receipt }
}

private actor BootstrapProbe {
    enum Event: Equatable { case activated, invalidated }
    private var recorded: [Event] = []
    func activate() { recorded.append(.activated) }
    func invalidate() { recorded.append(.invalidated) }
    func events() -> [Event] { recorded }
}
