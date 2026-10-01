import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the successful commit paths of the production mutation authority
/// (ARCHITECTURE.md "Controlled mutations and work orders"): an atomic
/// reservation writes the work order and one exclusion lock per reserved
/// resource, a separate server acknowledgement follows, every lifecycle step
/// is one audited conditional revision, completion applies the planned change
/// and releases the locks in one bounded conditional mutation, and a resolved
/// cancellation with a valid attestation releases the locks.
///
/// The server enforces every precondition, and the planner works from a mirror
/// of the same fixtures, so each commit is checked against current state.
@MainActor
final class ProductionFeatureMutationAuthorityCommitCharacterizationTests: XCTestCase {
    func testConnectWorkOrderLifecycleCommitsEachStepAsOneAuditedRevision() async throws {
        let harness = try await MutationAuthorityHarness.make(planned: true)
        let draft = try await stagedConnectDraft(harness)
        let lockKeys = Self.lockKeys(for: draft)

        let reservation = try await harness.reserve(draft)
        try await assertLocksHeld(lockKeys, by: reservation, digest: harness.expectedDigest(for: draft), on: harness.server)
        try await harness.authority.requestApproval(for: draft.id, authorization: harness.presentation, in: harness.namespace)
        try await harness.authority.beginExecution(
            workOrderID: draft.id, reservationID: reservation.id, intentDigest: reservation.exactIntentDigest, authorization: harness.presentation,
            in: harness.namespace)
        let beforeCompletion = await harness.server.committed.count
        try await harness.authority.complete(workOrderID: draft.id, evidence: [], authorization: harness.presentation, in: harness.namespace)

        let committed = await harness.server.committed
        XCTAssertEqual(committed.count, beforeCompletion + 1, "Completion must be exactly one mutation.")
        XCTAssertEqual(committed.map(\.workOrder.status), [.reserved, .reserved, .approved, .executing, .completed])
        XCTAssertEqual(committed.map(\.workOrder.revision), [0, 1, 2, 3, 4])
        XCTAssertEqual(committed.map(\.expectedWorkOrderRevision), [0, 0, 1, 2, 3])
        let order = try await harness.serverWorkOrder(draft.id)
        XCTAssertEqual(order.status, .completed)
        XCTAssertEqual(order.revision, 4)
        XCTAssertEqual(order.approvedBy, harness.session.actor.cloudKitUserRecordName)
        XCTAssertEqual(order.executedBy, harness.session.actor.cloudKitUserRecordName)
        try await assertAudited(committed, workOrderID: draft.id, harness: harness)
    }

    func testReservationIsCommittedBeforeItsAcknowledgementAndBothBeforeApproval() async throws {
        let harness = try await MutationAuthorityHarness.make(planned: true)
        let draft = try await stagedConnectDraft(harness)

        let reservation = try await harness.reserve(draft)
        try await harness.authority.requestApproval(for: draft.id, authorization: harness.presentation, in: harness.namespace)

        let committed = await harness.server.committed
        XCTAssertEqual(committed.count, 3)
        let (reserve, acknowledge, approve) = (committed[0], committed[1], committed[2])
        XCTAssertNil(reserve.workOrder.reservation?.acknowledgedByCloudKit, "Phase one has no server metadata to acknowledge yet.")
        XCTAssertEqual(Set(reserve.saves.map(\.resourceKey)), Self.lockKeys(for: draft))
        XCTAssertTrue(Self.lockKeys(for: draft).allSatisfy { reserve.preconditions.contains(.mustNotExist($0)) })
        // The acknowledgement binds the exact server metadata the reservation
        // commit produced: the fake's first accepted write is "server-1".
        let acknowledgement = try XCTUnwrap(acknowledge.workOrder.reservation?.acknowledgedByCloudKit)
        XCTAssertEqual(acknowledgement.changeTag, "server-1")
        XCTAssertEqual(acknowledgement.reservationID, reservation.id)
        XCTAssertEqual(acknowledgement.resourceKeys, draft.resourceKeys)
        XCTAssertEqual(acknowledgement.intentDigest, try harness.expectedDigest(for: draft))
        XCTAssertTrue(acknowledge.saves.isEmpty && acknowledge.tombstones.isEmpty, "The acknowledgement only revises the work order.")
        XCTAssertEqual(approve.workOrder.status, .approved)
        XCTAssertEqual(approve.workOrder.reservation?.acknowledgedByCloudKit, acknowledgement)
        XCTAssertEqual(reservation.confirmation, .confirmed)
        XCTAssertEqual(reservation.workOrderStatus, .reserved)
        XCTAssertEqual(reservation.resourceKeys, draft.resourceKeys)
        XCTAssertEqual(reservation.exactIntentDigest, try harness.expectedDigest(for: draft))
        XCTAssertEqual(reservation.expiresAt, acknowledgement.expiresAt)
    }

    func testCompletionAppliesThePlannedCableAndReleasesEveryLockInOneConditionalMutation() async throws {
        let harness = try await MutationAuthorityHarness.make(planned: true)
        let draft = try await stagedConnectDraft(harness)
        let cable = harness.topology.patch()
        let lockKeys = Self.lockKeys(for: draft)
        let reservation = try await harness.reserve(draft)
        try await harness.authority.requestApproval(for: draft.id, authorization: harness.presentation, in: harness.namespace)
        try await harness.authority.beginExecution(
            workOrderID: draft.id, reservationID: reservation.id, intentDigest: reservation.exactIntentDigest, authorization: harness.presentation,
            in: harness.namespace)
        let executingTag = try await harness.server.requiredSnapshot(for: .object(draft.id)).exactPrecondition

        try await harness.authority.complete(workOrderID: draft.id, evidence: [], authorization: harness.presentation, in: harness.namespace)

        let committed = await harness.server.committed
        let completion = try XCTUnwrap(committed.last)
        XCTAssertEqual(completion.saves.map(\.resourceKey), [.object(cable.id)])
        XCTAssertEqual(Set(completion.tombstones.map(\.resourceKey)), lockKeys)
        XCTAssertTrue(completion.preconditions.contains(.mustNotExist(.object(cable.id))), "A new cable must not already exist.")
        XCTAssertTrue(completion.preconditions.contains(.exactSystemFields(.object(draft.id), executingTag)))
        for key in lockKeys {
            XCTAssertTrue(completion.preconditions.contains(.exactSystemFields(key, ServiceFixture.exact("server-1"))), "\(key)")
        }
        XCTAssertEqual(completion.readAssertions.map(\.resourceKey), [ServiceFixture.sentinelKey(harness.namespace)])
        XCTAssertLessThanOrEqual(
            completion.saves.count + completion.tombstones.count + completion.readAssertions.count + 3,
            AtomicCloudMutation.maximumBusinessRecordsPerOperation)
        let saved = try await harness.server.requiredSnapshot(for: .object(cable.id))
        XCTAssertEqual(try CloudDeterministicCoding.decode(Cable.self, from: saved.payload), cable)
        for key in lockKeys {
            let lock = await harness.server.snapshot(for: key)
            XCTAssertNil(lock, "Completion must release \(key).")
        }
    }

    func testResolvedCancellationWithAValidAttestationReleasesTheLocks() async throws {
        let harness = try await MutationAuthorityHarness.make(planned: true)
        let draft = try await stagedConnectDraft(harness)
        let lockKeys = Self.lockKeys(for: draft)
        let reservation = try await harness.reserve(draft)

        let requested = try await harness.authority.requestCancellation(
            workOrderID: draft.id, reason: "Room closed", physicalStatus: .notStarted, authorization: harness.presentation, in: harness.namespace)
        let release = CancellationReleaseAuthorization.attestation(scope: try harness.releaseScope(for: requested), statement: "Nothing was patched.")
        try await harness.authority.resolveCancellation(
            workOrderID: draft.id, reason: "Released", releaseAuthorization: release, authorization: harness.presentation, in: harness.namespace)

        XCTAssertEqual(requested.id, reservation.id)
        XCTAssertEqual(requested.workOrderStatus, .cancellationRequested)
        XCTAssertEqual(requested.confirmation, .confirmed)
        let committed = await harness.server.committed
        XCTAssertEqual(committed.map(\.workOrder.status), [.reserved, .reserved, .cancellationRequested, .cancelled])
        XCTAssertEqual(committed.map(\.workOrder.revision), [0, 1, 2, 3])
        let resolution = try XCTUnwrap(committed.last)
        XCTAssertTrue(resolution.saves.isEmpty, "Cancellation applies no planned change.")
        XCTAssertEqual(Set(resolution.tombstones.map(\.resourceKey)), lockKeys)
        let order = try await harness.serverWorkOrder(draft.id)
        XCTAssertEqual(order.status, .cancelled)
        XCTAssertEqual(order.cancellationHistory.count, 1)
        XCTAssertEqual(order.cancellationHistory.last?.id, requested.cancellationRequestID)
        XCTAssertEqual(order.cancellationHistory.last?.releaseAuthorization, release)
        for key in lockKeys {
            let lock = await harness.server.snapshot(for: key)
            XCTAssertNil(lock, "Cancellation must release \(key).")
        }
        let cable = await harness.server.snapshot(for: .object(harness.topology.patch().id))
        XCTAssertNil(cable, "A cancelled connect must not create its cable.")
        try await assertAudited(committed, workOrderID: draft.id, harness: harness)
    }

    /// Payload timestamps are canonicalized and reserved key sets encode in a
    /// stable order, so a reservation with three reserved keys and live
    /// `.now` capture times must round-trip through canonical decoding on
    /// every attempt.
    func testReservationRoundTripsRepeatedlyWithLiveTimestamps() async throws {
        for attempt in 0..<20 {
            let harness = try await MutationAuthorityHarness.make()
            let draft = harness.connectDraft(ticket: "CHG-\(attempt)")
            XCTAssertEqual(draft.resourceKeys.count, 3)

            let reservation = try await harness.reserve(draft)
            let refreshed = try await harness.authority.refreshReservation(reservation, authorization: harness.presentation, in: harness.namespace)
            try await harness.authority.requestApproval(for: draft.id, authorization: harness.presentation, in: harness.namespace)

            XCTAssertEqual(reservation.confirmation, .confirmed, "attempt \(attempt)")
            XCTAssertEqual(refreshed, reservation, "attempt \(attempt)")
            let order = try await harness.serverWorkOrder(draft.id)
            XCTAssertEqual(order.status, .approved, "attempt \(attempt)")
            XCTAssertEqual(order.revision, 2, "attempt \(attempt)")
        }
    }

    // MARK: Helpers

    /// Stages the connect change through the feature entry point. A connect
    /// reserves the new cable and both of its endpoints.
    private func stagedConnectDraft(_ harness: MutationAuthorityHarness) async throws -> WorkOrderDraft {
        let cable = harness.topology.patch()
        let request = TopologyWorkOrderRequest(
            title: "Patch switch to panel", ticket: "CHG-100", notes: "", action: .connect(ConnectTopologyCommand(cable: cable)),
            resourceKeys: [.object(cable.id), .object(cable.endpointA), .object(cable.endpointB)])
        let id = try await harness.authority.stageTopology(request, in: harness.namespace)
        return try await harness.authority.stagedDraft(id: id, in: harness.namespace)
    }

    private static func lockKeys(for draft: WorkOrderDraft) -> Set<ResourceKey> {
        Set(draft.resourceKeys.map { ResourceKey.reservationLock(for: $0) })
    }

    private func assertLocksHeld(
        _ keys: Set<ResourceKey>, by reservation: WorkOrderReservationPresentation, digest: IntentDigest, on server: FakeCloudServer,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for key in keys {
            let snapshot = try await server.requiredSnapshot(for: key)
            let lock = try decoder.decode(ResourceReservationLock.self, from: snapshot.payload)
            XCTAssertEqual(lock.id, key, file: file, line: line)
            XCTAssertEqual(lock.workOrderID, reservation.workOrderID, file: file, line: line)
            XCTAssertEqual(lock.reservationID, reservation.id, file: file, line: line)
            XCTAssertEqual(lock.ownerID, "owner", file: file, line: line)
            XCTAssertEqual(lock.intentDigest, digest, file: file, line: line)
        }
    }

    /// Every step carries its own accepted audit event for the work order,
    /// written to the zone together with the change.
    private func assertAudited(
        _ committed: [AuthoritativeMutation], workOrderID: ObjectID, harness: MutationAuthorityHarness, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let audits = committed.map(\.auditEvent)
        XCTAssertEqual(Set(audits.map(\.id)).count, committed.count, "Each step needs its own audit event.", file: file, line: line)
        for (mutation, audit) in zip(committed, audits) {
            XCTAssertEqual(audit.operationID, mutation.operationID, file: file, line: line)
            XCTAssertEqual(audit.workOrderID, workOrderID, file: file, line: line)
            XCTAssertEqual(audit.actorID, harness.session.actor.cloudKitUserRecordName, file: file, line: line)
            XCTAssertEqual(audit.result, .accepted, file: file, line: line)
            XCTAssertEqual(audit.ticket, "CHG-100", file: file, line: line)
            XCTAssertEqual(audit.policyVersion, "service-test-policy", file: file, line: line)
            let stored = try await harness.server.requiredSnapshot(for: .object(audit.id))
            XCTAssertEqual(stored.recordType, CloudRecordNaming.auditRecordType, file: file, line: line)
        }
    }
}
