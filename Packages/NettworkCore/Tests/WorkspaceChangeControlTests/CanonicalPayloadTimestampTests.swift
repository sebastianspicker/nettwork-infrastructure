import Foundation
import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

/// Live-clock timestamps carry sub-millisecond precision that the millisecond
/// payload codec cannot represent. Every value that enters an immutable
/// mutation payload must therefore already survive one codec round trip.
final class CanonicalPayloadTimestampTests: XCTestCase {
    private let iterations = 200

    func testFactoryCreateMutationsPassImmutablePayloadValidationWithLiveSnapshots() throws {
        var failures: [String] = []
        for _ in 0..<iterations {
            let workspaceZone = zone()
            let sentinel = try sentinelAssertion(zone: workspaceZone)
            do {
                _ = try AuthoritativeWorkOrderMutationFactory.make(
                    operationID: ObjectID(), workspaceZone: workspaceZone, actor: liveActor(), currentWorkOrder: nil,
                    updatedWorkOrder: try makeDraft(keys: freshKeys()), state: .init(knownRecords: [sentinel.resourceKey: sentinel.precondition]),
                    readAssertions: [sentinel], policyVersion: "official-client-v1")
            } catch {
                failures.append(String(describing: error))
            }
        }
        XCTAssertEqual(failures.count, 0, "first failure: \(failures.first ?? "none")")
    }

    func testFactoryAcknowledgementMutationsPassImmutablePayloadValidationWithLiveSnapshots() throws {
        var failures: [String] = []
        for _ in 0..<iterations {
            do {
                try makeAcknowledgementMutation()
            } catch {
                failures.append(String(describing: error))
            }
        }
        XCTAssertEqual(failures.count, 0, "first failure: \(failures.first ?? "none")")
    }

    func testLifecycleAndAuditTimestampsSurviveThePayloadCodec() throws {
        var mismatches = 0
        for _ in 0..<iterations {
            let keys = freshKeys()
            var order = try makeDraft(keys: keys)
            order.reservation = WorkOrderReservation(ownerID: "technician", resourceKeys: Set(keys))
            order = try WorkOrderStateMachine.transition(order, to: .reserved, context: .init(actorID: "technician"))
            let approved = try WorkOrderStateMachine.transition(order, to: .approved, context: .init(actorID: "approver"))
            let cancelling = try WorkOrderStateMachine.requestCancellation(approved, reason: "Superseded", by: "technician")
            let audit = AuditEvent(operationID: ObjectID(), actorID: "technician", affectedObjectIDs: [], result: .accepted)
            if try roundTripped(cancelling) != cancelling { mismatches += 1 }
            if try roundTripped(audit) != audit { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0)
    }

    private func makeAcknowledgementMutation() throws {
        let keys = freshKeys()
        var reserved = try makeDraft(keys: keys)
        let reservation = WorkOrderReservation(ownerID: "technician", resourceKeys: Set(keys))
        reserved.reservation = reservation
        reserved = try WorkOrderStateMachine.transition(reserved, to: .reserved, context: .init(actorID: "technician"))
        let workspaceZone = zone()
        let acknowledgedAt = Date.now
        let acknowledgement = CloudKitAcknowledgement(
            workspaceZone: workspaceZone, cloudKitAccountRecordName: "technician", sessionGeneration: 1, reservationID: reservation.id,
            workOrderID: reserved.id, ownerID: "technician", resourceKeys: Set(keys), intentDigest: try XCTUnwrap(reserved.intentDigest),
            systemFields: Data([4, 2]), changeTag: "reserved-v1", acknowledgedAt: acknowledgedAt, expiresAt: acknowledgedAt.addingTimeInterval(3_600.123_456))
        let actor = liveActor()
        let acknowledged = try WorkOrderStateMachine.acknowledgeReservation(reserved, acknowledgement: acknowledgement, observedAt: actor.capturedAt)
        let sentinel = try sentinelAssertion(zone: workspaceZone)
        let state = AuthoritativeMutationState(
            knownRecords: [
                .object(reserved.id): ExactRecordPrecondition(systemFields: Data([9]), changeTag: "reserved-v1"),
                sentinel.resourceKey: sentinel.precondition,
            ],
            currentWorkOrder: reserved)
        _ = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: ObjectID(), workspaceZone: workspaceZone, actor: actor, currentWorkOrder: reserved, updatedWorkOrder: acknowledged,
            state: state, readAssertions: [sentinel], policyVersion: "official-client-v1")
    }

    private func roundTripped<Value: Codable>(_ value: Value) throws -> Value {
        try CanonicalJSONCoding.decode(Value.self, from: CanonicalJSONCoding.encode(value))
    }

    private func freshKeys() -> [ResourceKey] {
        (0..<5).map { _ in ResourceKey.object(ObjectID()) }
    }

    private func makeDraft(keys: [ResourceKey]) throws -> WorkOrder {
        let orderID = ObjectID()
        let operations = keys.map { PlannedWorkOperation.device(resourceKey: $0, description: "Update device") }
        let digest = try CanonicalWorkIntent(
            workOrderID: orderID, kind: .device, creatorID: "technician", ticket: "CHG-42", notes: nil, operations: operations,
            resourceKeys: Set(keys), evidenceHashes: []
        ).digest()
        return WorkOrder(
            id: orderID, kind: .device, title: "Update devices", creatorID: "technician", ticket: "CHG-42", plannedOperations: operations,
            intentDigest: digest)
    }

    private func liveActor() -> ActorInstallationSnapshot {
        ActorInstallationSnapshot(actorID: "technician", installationID: "ipad-1", sessionID: "session-1", sessionGeneration: 1, capturedAt: .now)
    }

    private func zone() -> AuthoritativeWorkspaceZone {
        AuthoritativeWorkspaceZone(workspaceID: ObjectID(), containerIdentifier: "iCloud.example.nettwork", zoneName: "workspace", zoneOwnerRecordName: "owner")
    }

    private func sentinelAssertion(zone: AuthoritativeWorkspaceZone) throws -> AuthoritativeReadAssertion {
        let payload = try JSONEncoder().encode(
            TimestampSentinelFixture(
                workspaceID: zone.workspaceID, zoneName: zone.zoneName, zoneOwnerRecordName: zone.zoneOwnerRecordName,
                lifecycle: .active(commit: WorkspaceActivationCommit(transferID: ObjectID(), memberCount: 0, rollingDigest: "active"))))
        return AuthoritativeReadAssertion(
            resourceKey: AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: zone.workspaceID),
            recordType: AuthoritativeActivationMutation.workspaceSentinelRecordType, schemaVersion: 1, encodedRecord: payload,
            precondition: ExactRecordPrecondition(systemFields: Data([7]), changeTag: "workspace-active"))
    }
}

private struct TimestampSentinelFixture: Codable {
    let workspaceID: ObjectID
    let zoneName: String
    let zoneOwnerRecordName: String
    let lifecycle: WorkspaceLifecycle
}
