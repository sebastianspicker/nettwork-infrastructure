import Foundation
import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class AuthoritativeWorkOrderMutationFactoryTests: XCTestCase {
    func testFactoryBuildsCompleteCreateMutation() throws {
        let fixture = try makeDraft()
        let actor = actorSnapshot()
        let workspaceZone = zone()
        let sentinel = try activeSentinelAssertion(zone: workspaceZone)
        let mutation = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: ObjectID(),
            workspaceZone: workspaceZone,
            actor: actor,
            currentWorkOrder: nil,
            updatedWorkOrder: fixture,
            state: .init(knownRecords: [sentinel.resourceKey: sentinel.precondition]),
            readAssertions: [sentinel],
            policyVersion: "official-client-v1"
        )

        XCTAssertEqual(mutation.resourceKeys.count, 3)
        XCTAssertEqual(mutation.auditEvent.actorID, actor.actorID)
        XCTAssertEqual(mutation.receipt.operationID, mutation.operationID)
        XCTAssertEqual(mutation.readAssertions, [sentinel])
    }

    func testFactoryUsesExactWorkOrderPreconditionForTransition() throws {
        let resourceKey = ResourceKey.object(ObjectID())
        let draft = try makeDraft(resourceKey: resourceKey)
        var reserved = draft
        reserved.reservation = WorkOrderReservation(ownerID: "technician", resourceKeys: [resourceKey])
        reserved = try WorkOrderStateMachine.transition(reserved, to: .reserved, context: .init(actorID: "technician"))
        let exact = ExactRecordPrecondition(systemFields: Data([1, 2]), changeTag: "work-order-v0")
        let workspaceZone = zone()
        let sentinel = try activeSentinelAssertion(zone: workspaceZone)
        let state = AuthoritativeMutationState(
            knownRecords: [
                .object(draft.id): exact,
                sentinel.resourceKey: sentinel.precondition,
            ],
            currentWorkOrder: draft
        )
        let mutation = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: ObjectID(),
            workspaceZone: workspaceZone,
            actor: actorSnapshot(),
            currentWorkOrder: draft,
            updatedWorkOrder: reserved,
            state: state,
            readAssertions: [sentinel],
            policyVersion: "official-client-v1"
        )

        XCTAssertTrue(mutation.preconditions.contains(.exactSystemFields(.object(draft.id), exact)))
        XCTAssertEqual(mutation.expectedWorkOrderRevision, 0)
        XCTAssertEqual(mutation.workOrder.revision, 1)
    }

    func testFactoryBuildsConditionalReservationAcknowledgementRevision() throws {
        let resourceKey = ResourceKey.object(ObjectID())
        var reserved = try makeDraft(resourceKey: resourceKey)
        let reservation = WorkOrderReservation(ownerID: "technician", resourceKeys: [resourceKey])
        reserved.reservation = reservation
        reserved = try WorkOrderStateMachine.transition(
            reserved,
            to: .reserved,
            context: .init(actorID: "technician", at: .distantPast)
        )
        let actor = actorSnapshot()
        let workspaceZone = zone()
        let acknowledgement = CloudKitAcknowledgement(
            workspaceZone: workspaceZone,
            cloudKitAccountRecordName: actor.actorID,
            sessionGeneration: actor.sessionGeneration,
            reservationID: reservation.id,
            workOrderID: reserved.id,
            ownerID: actor.actorID,
            resourceKeys: [resourceKey],
            intentDigest: reserved.intentDigest!,
            systemFields: Data([4, 2]),
            changeTag: "reserved-v1",
            acknowledgedAt: .distantPast,
            expiresAt: .distantFuture
        )
        let acknowledged = try WorkOrderStateMachine.acknowledgeReservation(
            reserved,
            acknowledgement: acknowledgement,
            observedAt: actor.capturedAt
        )
        let exact = ExactRecordPrecondition(systemFields: Data([9]), changeTag: "reserved-v1")
        let sentinel = try activeSentinelAssertion(zone: workspaceZone)
        let state = AuthoritativeMutationState(
            knownRecords: [
                .object(reserved.id): exact,
                sentinel.resourceKey: sentinel.precondition,
            ],
            currentWorkOrder: reserved
        )
        let mutation = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: ObjectID(),
            workspaceZone: workspaceZone,
            actor: actor,
            currentWorkOrder: reserved,
            updatedWorkOrder: acknowledged,
            state: state,
            readAssertions: [sentinel],
            policyVersion: "official-client-v1"
        )

        XCTAssertEqual(mutation.workOrder.status, .reserved)
        XCTAssertEqual(mutation.workOrder.revision, reserved.revision + 1)
        XCTAssertEqual(mutation.workOrder.reservation?.acknowledgedByCloudKit, acknowledgement)
        XCTAssertTrue(mutation.preconditions.contains(.exactSystemFields(.object(reserved.id), exact)))
    }

    private func makeDraft(resourceKey: ResourceKey = .object(ObjectID())) throws -> WorkOrder {
        let orderID = ObjectID()
        let operation = PlannedWorkOperation.device(resourceKey: resourceKey, description: "Update device")
        let digest = try CanonicalWorkIntent(
            workOrderID: orderID,
            kind: .device,
            creatorID: "technician",
            ticket: "CHG-42",
            notes: nil,
            operations: [operation],
            resourceKeys: [resourceKey],
            evidenceHashes: []
        ).digest()
        return WorkOrder(
            id: orderID,
            kind: .device,
            title: "Update device",
            creatorID: "technician",
            ticket: "CHG-42",
            plannedOperations: [operation],
            intentDigest: digest
        )
    }

    private func actorSnapshot() -> ActorInstallationSnapshot {
        ActorInstallationSnapshot(
            actorID: "technician",
            installationID: "ipad-1",
            sessionID: "session-1",
            sessionGeneration: 1,
            capturedAt: .distantPast
        )
    }

    private func zone() -> AuthoritativeWorkspaceZone {
        AuthoritativeWorkspaceZone(
            workspaceID: ObjectID(),
            containerIdentifier: "iCloud.example.nettwork",
            zoneName: "workspace",
            zoneOwnerRecordName: "owner"
        )
    }

    private func activeSentinelAssertion(
        zone: AuthoritativeWorkspaceZone
    ) throws -> AuthoritativeReadAssertion {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(
            for: zone.workspaceID
        )
        let payload = try JSONEncoder().encode(
            WorkspaceSentinelFixture(
                workspaceID: zone.workspaceID,
                zoneName: zone.zoneName,
                zoneOwnerRecordName: zone.zoneOwnerRecordName,
                lifecycle: .active(
                    commit: WorkspaceActivationCommit(
                        transferID: ObjectID(),
                        memberCount: 0,
                        rollingDigest: "active"
                    ))
            ))
        return AuthoritativeReadAssertion(
            resourceKey: key,
            recordType: AuthoritativeActivationMutation.workspaceSentinelRecordType,
            schemaVersion: 1,
            encodedRecord: payload,
            precondition: ExactRecordPrecondition(
                systemFields: Data([7]),
                changeTag: "workspace-active"
            )
        )
    }
}

private struct WorkspaceSentinelFixture: Codable {
    let workspaceID: ObjectID
    let zoneName: String
    let zoneOwnerRecordName: String
    let lifecycle: WorkspaceLifecycle
}
