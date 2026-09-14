import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudReservationAcknowledgementVerifierTests: XCTestCase {
    func testValidReservedServerSnapshotProducesAcknowledgement() throws {
        let fixture = try ReservationAcknowledgementFixture.make()
        let acknowledgement = try CloudReservationAcknowledgementVerifier.verify(
            reservedWorkOrder: fixture.reservedWorkOrder,
            serverRecord: fixture.serverRecord,
            account: fixture.account,
            actor: fixture.actor,
            expiresAt: fixture.expiresAt,
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(acknowledgement.workspaceZone, fixture.account.namespace.workspaceZone)
        XCTAssertEqual(acknowledgement.reservationID, fixture.reservationID)
        XCTAssertEqual(acknowledgement.workOrderID, fixture.workOrderID)
        XCTAssertEqual(acknowledgement.ownerID, fixture.actor.cloudKitUserRecordName)
        XCTAssertEqual(acknowledgement.resourceKeys, fixture.resourceKeys)
        XCTAssertEqual(acknowledgement.intentDigest, fixture.intentDigest)
        XCTAssertEqual(acknowledgement.systemFields, fixture.serverRecord.exactPrecondition.systemFields)
        XCTAssertEqual(acknowledgement.changeTag, fixture.serverRecord.exactPrecondition.changeTag)
        XCTAssertEqual(acknowledgement.acknowledgedAt, fixture.serverModifiedAt)
        XCTAssertEqual(acknowledgement.expiresAt, fixture.expiresAt)
    }

    func testVerifierRejectsSnapshotFromWrongWorkspace() throws {
        let fixture = try ReservationAcknowledgementFixture.make()
        let wrongWorkspace = AuthoritativeWorkspaceZone(
            workspaceID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!),
            containerIdentifier: fixture.account.namespace.containerIdentifier,
            zoneName: "nettwork.workspace.wrong",
            zoneOwnerRecordName: fixture.actor.cloudKitUserRecordName
        )
        let serverRecord = try fixture.serverRecord(for: fixture.reservedWorkOrder, workspaceZone: wrongWorkspace)

        assertVerificationError(.invalidAccountScope) {
            _ = try CloudReservationAcknowledgementVerifier.verify(
                reservedWorkOrder: fixture.reservedWorkOrder,
                serverRecord: serverRecord,
                account: fixture.account,
                actor: fixture.actor,
                expiresAt: fixture.expiresAt,
                observedAt: fixture.observedAt
            )
        }
    }

    func testVerifierRejectsReservationOwnedByAnotherActor() throws {
        let fixture = try ReservationAcknowledgementFixture.make()
        let wrongOwnerOrder = try fixture.workOrder(ownerID: "other-record")
        let serverRecord = try fixture.serverRecord(for: wrongOwnerOrder)

        assertVerificationError(.invalidActor) {
            _ = try CloudReservationAcknowledgementVerifier.verify(
                reservedWorkOrder: wrongOwnerOrder,
                serverRecord: serverRecord,
                account: fixture.account,
                actor: fixture.actor,
                expiresAt: fixture.expiresAt,
                observedAt: fixture.observedAt
            )
        }
    }

    func testVerifierRejectsTamperedServerPayload() throws {
        let fixture = try ReservationAcknowledgementFixture.make()
        var tamperedOrder = fixture.reservedWorkOrder
        tamperedOrder.title = "Tampered title"
        let serverRecord = try fixture.serverRecord(for: tamperedOrder)

        assertVerificationError(.recordMismatch) {
            _ = try CloudReservationAcknowledgementVerifier.verify(
                reservedWorkOrder: fixture.reservedWorkOrder,
                serverRecord: serverRecord,
                account: fixture.account,
                actor: fixture.actor,
                expiresAt: fixture.expiresAt,
                observedAt: fixture.observedAt
            )
        }
    }

    func testVerifierRejectsChangedCanonicalIntent() throws {
        let fixture = try ReservationAcknowledgementFixture.make()
        let changedIntentOrder = try fixture.workOrder(notes: "Changed after reservation", intentDigest: fixture.intentDigest)
        let serverRecord = try fixture.serverRecord(for: changedIntentOrder)

        assertVerificationError(.intentMismatch) {
            _ = try CloudReservationAcknowledgementVerifier.verify(
                reservedWorkOrder: changedIntentOrder,
                serverRecord: serverRecord,
                account: fixture.account,
                actor: fixture.actor,
                expiresAt: fixture.expiresAt,
                observedAt: fixture.observedAt
            )
        }
    }

    func testVerifierRejectsExpiredAcknowledgementWindow() throws {
        let fixture = try ReservationAcknowledgementFixture.make()

        assertVerificationError(.invalidAcknowledgementWindow) {
            _ = try CloudReservationAcknowledgementVerifier.verify(
                reservedWorkOrder: fixture.reservedWorkOrder,
                serverRecord: fixture.serverRecord,
                account: fixture.account,
                actor: fixture.actor,
                expiresAt: fixture.observedAt,
                observedAt: fixture.observedAt
            )
        }
    }

    private func assertVerificationError(
        _ expected: CloudReservationAcknowledgementError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? CloudReservationAcknowledgementError, expected)
        }
    }
}

private struct ReservationAcknowledgementFixture {
    let workspaceID: ObjectID
    let workOrderID: ObjectID
    let reservationID: ObjectID
    let resourceID: ObjectID
    let serverModifiedAt: Date
    let observedAt: Date
    let expiresAt: Date
    let account: AccountContext
    let actor: ActorContext
    let resourceKeys: Set<ResourceKey>
    let intentDigest: IntentDigest
    let reservedWorkOrder: WorkOrder
    let serverRecord: CloudExactRecordSnapshot

    static func make() throws -> ReservationAcknowledgementFixture {
        let workspaceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let workOrderID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let reservationID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let resourceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        let serverModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let observedAt = Date(timeIntervalSince1970: 1_700_000_030)
        let expiresAt = Date(timeIntervalSince1970: 1_700_000_300)
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "owner-record", workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID), zoneOwnerRecordName: "owner-record", sessionGeneration: 7)
        let account = AccountContext(namespace: namespace, databaseScope: .ownerPrivate, sharePermission: .owner, verifiedAt: observedAt)
        let actor = ActorContext(
            cloudKitUserRecordName: "owner-record", role: .technician, installationID: "test-installation", sessionGeneration: namespace.sessionGeneration)
        let resourceKeys: Set<ResourceKey> = [.object(resourceID)]
        let operations: [PlannedWorkOperation] = [.device(resourceKey: .object(resourceID), description: "Install edge port")]
        let intentDigest = try CanonicalWorkIntent(
            workOrderID: workOrderID, kind: .device, creatorID: actor.cloudKitUserRecordName, ticket: "CHG-123", notes: "Install the new edge port",
            operations: operations, resourceKeys: resourceKeys, evidenceHashes: []
        ).digest()
        let reservation = WorkOrderReservation(id: reservationID, ownerID: actor.cloudKitUserRecordName, resourceKeys: resourceKeys)
        let workOrder = WorkOrder(
            id: workOrderID, kind: .device, title: "Install edge port", status: .reserved, creatorID: actor.cloudKitUserRecordName, ticket: "CHG-123",
            notes: "Install the new edge port", plannedOperations: operations, intentDigest: intentDigest, reservation: reservation)
        let serverRecord = try Self.makeServerRecord(for: workOrder, workspaceZone: namespace.workspaceZone, serverModifiedAt: serverModifiedAt)
        return ReservationAcknowledgementFixture(
            workspaceID: workspaceID, workOrderID: workOrderID, reservationID: reservationID, resourceID: resourceID, serverModifiedAt: serverModifiedAt,
            observedAt: observedAt, expiresAt: expiresAt, account: account, actor: actor, resourceKeys: resourceKeys, intentDigest: intentDigest,
            reservedWorkOrder: workOrder, serverRecord: serverRecord)
    }

    func workOrder(ownerID: String = "owner-record", notes: String? = "Install the new edge port", intentDigest: IntentDigest? = nil) throws -> WorkOrder {
        let operations: [PlannedWorkOperation] = [.device(resourceKey: .object(resourceID), description: "Install edge port")]
        let canonicalIntent = CanonicalWorkIntent(
            workOrderID: workOrderID,
            kind: .device,
            creatorID: actor.cloudKitUserRecordName,
            ticket: "CHG-123",
            notes: notes,
            operations: operations,
            resourceKeys: resourceKeys,
            evidenceHashes: []
        )
        let digest: IntentDigest
        if let intentDigest {
            digest = intentDigest
        } else {
            digest = try canonicalIntent.digest()
        }
        let reservation = WorkOrderReservation(id: reservationID, ownerID: ownerID, resourceKeys: resourceKeys)
        return WorkOrder(
            id: workOrderID,
            kind: .device,
            title: "Install edge port",
            status: .reserved,
            creatorID: actor.cloudKitUserRecordName,
            ticket: "CHG-123",
            notes: notes,
            plannedOperations: operations,
            intentDigest: digest,
            reservation: reservation
        )
    }

    func serverRecord(
        for workOrder: WorkOrder,
        workspaceZone: AuthoritativeWorkspaceZone? = nil
    ) throws -> CloudExactRecordSnapshot {
        try Self.makeServerRecord(
            for: workOrder,
            workspaceZone: workspaceZone ?? account.namespace.workspaceZone,
            serverModifiedAt: serverModifiedAt
        )
    }

    private static func makeServerRecord(
        for workOrder: WorkOrder,
        workspaceZone: AuthoritativeWorkspaceZone,
        serverModifiedAt: Date
    ) throws -> CloudExactRecordSnapshot {
        try acknowledgementServerRecord(for: workOrder, workspaceZone: workspaceZone, serverModifiedAt: serverModifiedAt)
    }
}
