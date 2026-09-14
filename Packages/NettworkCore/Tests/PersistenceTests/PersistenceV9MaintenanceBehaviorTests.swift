import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Persistence

final class PersistenceV9MaintenanceBehaviorTests: XCTestCase {
    func testNewMaintenanceStateStartsIncompleteUntilARepairCommits() {
        let state = LocalMirrorMaintenanceStateModel(namespace: makeNamespace())

        XCTAssertEqual(state.schemaVersion, LocalMirrorMaintenanceLimits.schemaVersion)
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(state.referenceEdgeCount, 0)
        XCTAssertEqual(state.assetOwnerCount, 0)
        XCTAssertEqual(state.transferMemberCount, 0)
    }

    func testMaintenanceBatchCarriesItsCompletenessExplicitly() {
        let key = ResourceKey.string("maintenance-record")
        let complete = LocalMirrorMaintenanceBatch(records: [LocalMirrorMaintenanceRecord(resourceKey: key)])
        let incomplete = LocalMirrorMaintenanceBatch(records: [LocalMirrorMaintenanceRecord(resourceKey: key)], isComplete: false)

        XCTAssertTrue(complete.isComplete)
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(complete.records, incomplete.records)
    }

    func testMaintenanceLimitMatchesTheStagedTransferMemberLimit() {
        XCTAssertEqual(LocalMirrorMaintenanceLimits.maximumTransferMembers, 200)
        XCTAssertEqual(LocalMirrorMaintenanceLimits.schemaVersion, 9)
    }

    private func makeNamespace() -> PersistenceNamespace {
        let workspaceID = ObjectID()
        return PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "maintenance-owner",
            workspaceID: workspaceID, zoneName: "maintenance-zone", zoneOwnerRecordName: "maintenance-owner", sessionGeneration: 1
        )
    }
}
