import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

/// Pins draft validation, staging and the two-phase reservation of the
/// production mutation authority (ARCHITECTURE.md "Controlled mutations and
/// work orders"): presentation authorization is an assertion only, an atomic
/// reservation is followed by a separate server acknowledgement, and nothing
/// is committed for an invalid, stale or inactive request.
@MainActor
final class ProductionFeatureMutationAuthorityCharacterizationTests: XCTestCase {
    // MARK: Validation

    func testValidateDraftReturnsTheCanonicalIntentDigestOfTheTrustedCreator() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.connectDraft(ticket: "  CHG-100 \n")

        let validation = try await harness.authority.validateDraft(draft, authorization: harness.presentation, in: harness.namespace)

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.issues, [])
        XCTAssertEqual(validation.exactIntentDigest, try harness.expectedDigest(for: draft))
        let validatorCalls = await harness.validator.callCount
        XCTAssertEqual(validatorCalls, 1)
    }

    func testValidateDraftReportsStructuralIssuesWithoutConsultingTheMirror() async throws {
        let harness = try await MutationAuthorityHarness.make()

        let validation = try await harness.authority.validateDraft(WorkOrderDraft(title: "  "), authorization: harness.presentation, in: harness.namespace)

        XCTAssertFalse(validation.isValid)
        XCTAssertNil(validation.exactIntentDigest)
        XCTAssertEqual(validation.issues.count, 4, "title, ticket, operations and resource set are each required")
        let validatorCalls = await harness.validator.callCount
        XCTAssertEqual(validatorCalls, 0)
    }

    func testValidateDraftRequiresTheResourceSetToCoverEveryOperation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        var draft = harness.connectDraft()
        draft.resourceKeys = [.object(harness.topology.switchPort.id)]

        let validation = try await harness.authority.validateDraft(draft, authorization: harness.presentation, in: harness.namespace)

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.issues.count, 1)
    }

    func testValidateDraftSurfacesSemanticIssuesFromTheCurrentSnapshot() async throws {
        let harness = try await MutationAuthorityHarness.make()
        await harness.validator.setIssues(["Port is occupied."])

        let validation = try await harness.authority.validateDraft(harness.connectDraft(), authorization: harness.presentation, in: harness.namespace)

        XCTAssertEqual(validation, WorkOrderValidation(isValid: false, exactIntentDigest: nil, issues: ["Port is occupied."]))
    }

    func testValidateDraftRejectsAMismatchedPresentationBeforeValidation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let forged = OperationsAuthorization(
            actorID: "someone-else", role: .administrator, sessionGeneration: harness.session.actor.sessionGeneration, isFresh: true)

        await assertThrows(ProductionSessionAuthorizationError.presentationMismatch) {
            try await harness.authority.validateDraft(harness.connectDraft(), authorization: forged, in: harness.namespace)
        }
        let validatorCalls = await harness.validator.callCount
        XCTAssertEqual(validatorCalls, 0)
    }

    // MARK: Staging

    func testStagedTopologyDraftIsRetrievableOnlyInItsNamespace() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let cable = harness.topology.patch()
        let keys: Set<ResourceKey> = [.object(cable.id), .object(cable.endpointA), .object(cable.endpointB)]
        let command = ConnectTopologyCommand(cable: cable)
        let request = TopologyWorkOrderRequest(title: "Patch", ticket: "CHG-7", notes: "", action: .connect(command), resourceKeys: keys)

        let id = try await harness.authority.stageTopology(request, in: harness.namespace)
        let staged = try await harness.authority.stagedDraft(id: id, in: harness.namespace)

        XCTAssertEqual(staged.kind, .connect)
        XCTAssertEqual(staged.resourceKeys, keys)
        XCTAssertEqual(staged.operations, [.topology(.connect(command))])
        await assertThrows(ProductionFeatureMutationAuthorityError.namespaceMismatch) {
            try await harness.authority.stagedDraft(id: id, in: ServiceFixture.namespace())
        }
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty, "Staging a draft must not reserve or mutate anything.")
    }

    func testStagingEnforcesRoleAndSupportedActions() async throws {
        let technician = try await MutationAuthorityHarness.make(role: .technician)
        let hierarchy = HierarchyFixture()
        let rackRequest = TopologyWorkOrderRequest(
            title: "Add rack", ticket: "CHG-8", notes: "", action: .hierarchy(.upsertRack(hierarchy.rack)), resourceKeys: [.object(hierarchy.rack.id)])
        let removeRequest = TopologyWorkOrderRequest(
            title: "Remove", ticket: "CHG-9", notes: "",
            action: .remove(RemoveTopologyCommand(deviceID: technician.topology.panelDevice.id)),
            resourceKeys: [.object(technician.topology.panelDevice.id)])

        await assertThrows(OfficialClientPolicyError.technicianCannotAdminister) {
            try await technician.authority.stageTopology(rackRequest, in: technician.namespace)
        }
        await assertThrows(ProductionFeatureMutationAuthorityError.unsupportedDraft) {
            try await technician.authority.stageTopology(removeRequest, in: technician.namespace)
        }
    }

    func testStageIPAMRequiresTheRequestToBeScopedToItsVRFRevision() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let ipam = IPAMFixture(deviceID: harness.topology.switchDevice.id)
        let assignment = IPAddressAssignment(addressID: ipam.address.id, interfaceID: ipam.interface.id, isPrimary: true)
        let set = InterfaceAddressAssignmentSet(
            revisionVRF: ipam.vrf, interfaceID: ipam.interface.id, currentAssignments: [], desiredAssignments: [assignment], primaryAddressID: ipam.address.id)
        let misScoped = IPAMWorkOrderRequest(
            title: "Assign", ticketID: "CHG-10", notes: "", perVRFRevisionKey: .object(ObjectID()), operation: .addressAssignment(set))
        let scoped = IPAMWorkOrderRequest(
            title: "Assign", ticketID: "CHG-10", notes: "", perVRFRevisionKey: .object(ipam.vrf.id), operation: .addressAssignment(set))

        await assertThrows(ProductionFeatureMutationAuthorityError.unsupportedDraft) {
            try await harness.authority.stageIPAM(misScoped, in: harness.namespace)
        }
        let id = try await harness.authority.stageIPAM(scoped, in: harness.namespace)
        let staged = try await harness.authority.stagedDraft(id: id, in: harness.namespace)
        XCTAssertEqual(staged.kind, .ipam)
        XCTAssertTrue(
            staged.resourceKeys.isSuperset(of: [.object(ipam.vrf.id), .object(ipam.interface.id), .object(assignment.id), .string(ipam.address.id)]))
    }

    // MARK: Reservation

    func testReserveCommitsNothingForAnInvalidDraft() async throws {
        let harness = try await MutationAuthorityHarness.make()
        await harness.validator.setIssues(["stale snapshot"])

        await assertThrows(ProductionFeatureMutationAuthorityError.invalidDraft(["stale snapshot"])) {
            try await harness.reserve(harness.connectDraft())
        }
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty)
    }

    func testReserveCommitsNothingWhileTheWorkspaceIsInactive() async throws {
        let harness = try await MutationAuthorityHarness.make()
        try await harness.server.putSentinel(harness.namespace, lifecycle: .empty(epoch: 1))

        await assertThrows(ProductionFeatureMutationAuthorityError.workspaceInactive) {
            try await harness.reserve(harness.connectDraft())
        }
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty)
    }

    func testReserveCommitsNothingAfterTheSessionIsSuperseded() async throws {
        let harness = try await MutationAuthorityHarness.make()
        await harness.session.workspaceAuthority.setMembership(nil)

        await assertThrows(ProductionSessionAuthorizationError.noVerifiedSession) {
            try await harness.reserve(harness.connectDraft())
        }
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty)
    }

    func testRefreshReservationConfirmsOnlyTheExactAcknowledgedReservation() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let draft = harness.singleResourceDraft()
        let seeded = try await harness.seedReservedOrder(draft, expiresAt: ServiceFixture.wholeSeconds(fromNow: 600))
        var changed = draft
        changed.ticket = "CHG-OTHER"
        let reservation = seeded.presentation
        let tampered = WorkOrderReservationPresentation(
            id: reservation.id, workOrderID: reservation.workOrderID, exactIntentDigest: try harness.expectedDigest(for: changed),
            resourceKeys: reservation.resourceKeys, expiresAt: reservation.expiresAt, confirmation: reservation.confirmation,
            workOrderStatus: reservation.workOrderStatus, cancellationRequestID: nil)

        let refreshed = try await harness.authority.refreshReservation(reservation, authorization: harness.presentation, in: harness.namespace)

        XCTAssertEqual(refreshed, reservation)
        await assertThrows(ProductionFeatureMutationAuthorityError.invalidReservation) {
            try await harness.authority.refreshReservation(tampered, authorization: harness.presentation, in: harness.namespace)
        }
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty, "Refreshing a reservation is read-only.")
    }

    func testRefreshReservationReportsAnExpiredAcknowledgement() async throws {
        let harness = try await MutationAuthorityHarness.make()
        let seeded = try await harness.seedReservedOrder(harness.singleResourceDraft(), expiresAt: ServiceFixture.epoch.addingTimeInterval(3_600))

        let refreshed = try await harness.authority.refreshReservation(seeded.presentation, authorization: harness.presentation, in: harness.namespace)

        XCTAssertEqual(refreshed.confirmation, .expired)
    }
}
