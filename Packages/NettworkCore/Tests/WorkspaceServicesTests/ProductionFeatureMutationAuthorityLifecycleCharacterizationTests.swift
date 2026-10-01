import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the work-order lifecycle guards of the production mutation authority:
/// execution needs the acknowledged reservation and exact intent, completion
/// material must stay inside the reservation, cancellation must carry release
/// evidence bound to the live session (or an administrator override), and the
/// immutable audit export is revalidated between staging and publication.
/// Every rejection must happen before any Cloud mutation is committed.
@MainActor
final class ProductionFeatureMutationAuthorityLifecycleCharacterizationTests: XCTestCase {
    func testBeginExecutionRequiresTheAcknowledgedReservationAndExactIntent() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        let seeded = try await harness.seedReservedOrder(draft, status: .approved)
        var changed = draft
        changed.ticket = "CHG-OTHER"

        await assertThrows(ProductionFeatureMutationAuthorityError.reservationNotAcknowledged) {
            try await harness.authority.beginExecution(
                workOrderID: draft.id, reservationID: ObjectID(), intentDigest: seeded.presentation.exactIntentDigest,
                authorization: harness.presentation, in: harness.namespace)
        }
        await assertThrows(ProductionFeatureMutationAuthorityError.reservationNotAcknowledged) {
            try await harness.authority.beginExecution(
                workOrderID: draft.id, reservationID: seeded.presentation.id, intentDigest: try harness.expectedDigest(for: changed),
                authorization: harness.presentation, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    func testCommandsForAnUnknownWorkOrderFail() async throws {
        let harness = try await MutationAuthorityHarness.make()

        await assertThrows(ProductionFeatureMutationAuthorityError.workOrderMissing) {
            try await harness.authority.requestApproval(for: ObjectID(), authorization: harness.presentation, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    func testCommandsRejectAStalePresentation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        try await harness.seedReservedOrder(draft)
        let stale = ServiceFixture.presentation(for: harness.session.actor, isFresh: false)

        await assertThrows(ProductionSessionAuthorizationError.presentationMismatch) {
            try await harness.authority.requestApproval(for: draft.id, authorization: stale, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    func testCompletionRejectsMaterialOutsideTheReservation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        try await harness.seedReservedOrder(draft, status: .executing)
        let outside = ResourceKey.object(ObjectID())
        await harness.materializer.setMaterial(
            ProductionMutationMaterial(
                saves: [AuthoritativeRecordSave(resourceKey: outside, recordType: "Cable", schemaVersion: 1, encodedRecord: Data("{}".utf8))],
                touchedPreconditions: [outside: .mustNotExist(outside)]))

        await assertThrows(ProductionFeatureMutationAuthorityError.materialOutsideReservation(outside)) {
            try await harness.authority.complete(workOrderID: draft.id, evidence: [], authorization: harness.presentation, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    func testRequestCancellationRequiresAnActiveReservation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        try await harness.seedReservedOrder(draft, status: .cancellationRequested)

        await assertThrows(ProductionFeatureMutationAuthorityError.invalidCancellationRequestState) {
            try await harness.authority.requestCancellation(
                workOrderID: draft.id, reason: "Again", physicalStatus: .notStarted, authorization: harness.presentation, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    func testResolveCancellationRequiresARequestedCancellation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        let seeded = try await harness.seedReservedOrder(draft)
        let scope = CancellationReleaseScope(
            workspaceZone: harness.namespace.workspaceZone, workOrderID: draft.id, reservationID: seeded.presentation.id,
            cancellationRequestID: ObjectID(), actorID: harness.session.actor.cloudKitUserRecordName, installationID: harness.session.actor.installationID,
            sessionID: "session-1", sessionGeneration: harness.session.actor.sessionGeneration, issuedAt: ServiceFixture.epoch,
            expiresAt: .distantFuture)

        await assertThrows(ProductionFeatureMutationAuthorityError.cancellationNotRequested) {
            try await harness.authority.resolveCancellation(
                workOrderID: draft.id, reason: "Released", releaseAuthorization: .attestation(scope: scope, statement: "Nothing was patched."),
                authorization: harness.presentation, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    func testResolveCancellationRejectsReleaseEvidenceNotBoundToTheLiveSession() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        let seeded = try await harness.seedReservedOrder(draft, status: .cancellationRequested)
        let otherSession = try harness.releaseScope(for: seeded.presentation, sessionID: "session-2")
        let current = try harness.releaseScope(for: seeded.presentation)
        let invalid: [CancellationReleaseAuthorization] = [
            .attestation(scope: otherSession, statement: "Nothing was patched."),
            .attestation(scope: current, statement: "   "),
            .emergencyOverride(scope: current, reason: ""),
        ]

        for release in invalid {
            await assertThrows(ProductionFeatureMutationAuthorityError.invalidCancellationReleaseAuthorization) {
                try await harness.authority.resolveCancellation(
                    workOrderID: draft.id, reason: "Released", releaseAuthorization: release, authorization: harness.presentation, in: harness.namespace)
            }
        }
        await assertNothingCommitted(harness)
    }

    func testEmergencyOverrideRequiresAnAdministrator() async throws {
        let harness = try await MutationAuthorityHarness.make(role: .technician)
        let draft = harness.singleResourceDraft()
        let seeded = try await harness.seedReservedOrder(draft, status: .cancellationRequested)
        let override = CancellationReleaseAuthorization.emergencyOverride(scope: try harness.releaseScope(for: seeded.presentation), reason: "Outage")

        await assertThrows(ProductionFeatureMutationAuthorityError.invalidCancellationReleaseAuthorization) {
            try await harness.authority.resolveCancellation(
                workOrderID: draft.id, reason: "Released", releaseAuthorization: override, authorization: harness.presentation, in: harness.namespace)
        }
        await assertNothingCommitted(harness)
    }

    // MARK: Immutable audit export

    func testAuditExportIsPublishedOnlyAfterRevalidation() async throws {
        let harness = try await MutationAuthorityHarness.make()

        let url = try await harness.authority.exportImmutableAudit(authorization: harness.session.operationContext(.exportAudit), in: harness.namespace)

        XCTAssertEqual(url, URL(fileURLWithPath: "/dev/null"))
        let events = await harness.exporter.events
        XCTAssertEqual(events, ["prepare", "publish"])
    }

    func testAuditExportIsAbortedWhenTheSessionChangesAfterStaging() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let actors = harness.session.actors
        let replacement = ServiceFixture.actor(for: harness.session.account, installationID: "installation-2")
        await harness.exporter.setAfterPrepare { await actors.setActor(replacement) }

        await assertThrows(ProductionSessionAuthorizationError.sessionSuperseded) {
            try await harness.authority.exportImmutableAudit(authorization: harness.session.operationContext(.exportAudit), in: harness.namespace)
        }
        let events = await harness.exporter.events
        XCTAssertEqual(events, ["prepare", "abort"])
    }

    func testAuditExportRequiresAnAdministratorExportAuditContext() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let technician = try await MutationAuthorityHarness.make(role: .technician)

        await assertThrows(ProductionFeatureMutationAuthorityError.namespaceMismatch) {
            try await harness.authority.exportImmutableAudit(authorization: harness.session.operationContext(.exportCSV), in: harness.namespace)
        }
        await assertThrows(OfficialClientPolicyError.technicianCannotAdminister) {
            try await technician.authority.exportImmutableAudit(
                authorization: technician.session.operationContext(.exportAudit), in: technician.namespace)
        }
        let events = await harness.exporter.events
        let technicianEvents = await technician.exporter.events
        XCTAssertEqual(events + technicianEvents, [])
    }

    private func assertNothingCommitted(_ harness: MutationAuthorityHarness, file: StaticString = #filePath, line: UInt = #line) async {
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty, "Rejected lifecycle commands must not commit a Cloud mutation.", file: file, line: line)
    }
}
