import XCTest

@testable import NetworkModel
@testable import WorkspaceChangeControl

final class AuthoritativeMutationWorkOrderReservationTests: XCTestCase {
    func testAllTransitionsAndSelfApprovalAreExplicit() throws {
        let resourceID = ObjectID()
        let order = try makeOrder(reservedResourceIDs: [resourceID])
        let reserved = try WorkOrderStateMachine.transition(order, to: .reserved, context: .init(actorID: "creator"))
        let approved = try WorkOrderStateMachine.transition(reserved, to: .approved, context: .init(actorID: "creator"))
        XCTAssertEqual(approved.approvedBy, "creator")
        XCTAssertEqual(approved.revision, 2)
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(approved, to: .executing, context: .init(actorID: "executor"))) { error in
            XCTAssertEqual(error as? WorkOrderTransitionError, .cloudKitAcknowledgementMismatch)
        }
        let executing = try WorkOrderStateMachine.transition(approved, to: .executing, context: .init(actorID: "creator"))
        let completed = try WorkOrderStateMachine.transition(executing, to: .completed, context: .init(actorID: "creator"))
        XCTAssertEqual(completed.executedBy, "creator")
        XCTAssertNotNil(completed.completedAt)

        for status in WorkOrderStatus.allCases {
            if status != .reserved && status != .cancelled {
                XCTAssertThrowsError(try WorkOrderStateMachine.transition(order, to: status, context: .init(actorID: "creator")))
            }
        }
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(approved, to: .completed, context: .init(actorID: "creator")))
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(completed, to: .executing, context: .init(actorID: "creator")))

        let unacknowledged = WorkOrder(
            kind: .connect, title: "Legacy", reservedResourceIDs: [resourceID], creatorID: "creator", intentDigest: order.intentDigest)
        let unacknowledgedReserved = try WorkOrderStateMachine.transition(unacknowledged, to: .reserved)
        let unacknowledgedApproved = try WorkOrderStateMachine.transition(unacknowledgedReserved, to: .approved)
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(unacknowledgedApproved, to: .executing)) { error in
            XCTAssertEqual(error as? WorkOrderTransitionError, .cloudKitAcknowledgementRequired)
        }
    }

    func testUnknownPhysicalCancellationRequiresAttestationOrEmergencyOverride() throws {
        let order = try makeOrder(reservedResourceIDs: [ObjectID()])
        let reserved = try WorkOrderStateMachine.transition(order, to: .reserved)
        let approved = try WorkOrderStateMachine.transition(reserved, to: .approved)
        let executing = try WorkOrderStateMachine.transition(approved, to: .executing)
        let requested = try WorkOrderStateMachine.requestCancellation(executing, reason: "Technician unreachable", by: "administrator")
        XCTAssertEqual(requested.status, .cancellationRequested)
        XCTAssertEqual(requested.cancellationHistory.last?.physicalStatus, .unknown)
        XCTAssertThrowsError(try WorkOrderStateMachine.transition(requested, to: .cancelled, cancellationReason: "Technician unreachable"))

        let cancellation = try XCTUnwrap(requested.cancellationHistory.last)
        let reservation = try XCTUnwrap(requested.reservation)
        let scope = CancellationReleaseScope(
            workspaceZone: AuthoritativeWorkspaceZone(
                workspaceID: ObjectID(),
                containerIdentifier: "iCloud.example",
                zoneName: "zone",
                zoneOwnerRecordName: "owner"
            ),
            workOrderID: requested.id,
            reservationID: reservation.id,
            cancellationRequestID: cancellation.id,
            actorID: "administrator",
            installationID: "installation",
            sessionID: "session",
            sessionGeneration: 1,
            issuedAt: .distantPast,
            expiresAt: .distantFuture
        )
        let authorization = CancellationReleaseAuthorization.emergencyOverride(
            scope: scope,
            reason: "Safety incident"
        )
        let cancelled = try WorkOrderStateMachine.resolveCancellation(
            requested, reason: "Technician unreachable", authorization: authorization, at: .distantFuture)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.cancellationHistory.last?.releaseAuthorization, authorization)
    }

    func testMutationValidatorRejectsIntentAuditRevisionAndPreconditionFailures() throws {
        let mutation = try makeMutation()
        try AuthoritativeMutationValidator.validate(mutation, against: validationState(for: mutation))

        var staleOrder = baseWorkOrder(for: mutation)
        staleOrder = try WorkOrderStateMachine.transition(staleOrder, to: .reserved)
        XCTAssertThrowsError(try AuthoritativeMutationValidator.validate(mutation, against: validationState(for: mutation, currentWorkOrder: staleOrder))) {
            error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .staleWorkOrderRevision(expected: 0, actual: 1))
        }

        let wrongDigest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 9, count: 32))
        let wrongIntent = try AuthoritativeMutation(
            workspaceZone: mutation.workspaceZone, operationID: mutation.operationID, intentDigest: wrongDigest, actor: mutation.actor,
            workOrder: mutation.workOrder, expectedWorkOrderRevision: 0, resourceKeys: mutation.resourceKeys, saves: mutation.saves,
            tombstones: mutation.tombstones, preconditions: mutation.preconditions, readAssertions: mutation.readAssertions, auditEvent: mutation.auditEvent,
            evidenceHashes: mutation.evidenceHashes)
        XCTAssertThrowsError(try AuthoritativeMutationValidator.validate(wrongIntent, against: validationState(for: mutation))) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .intentDigestMismatch)
        }

        let incomplete = try AuthoritativeMutation(
            workspaceZone: mutation.workspaceZone, operationID: mutation.operationID, intentDigest: mutation.intentDigest, actor: mutation.actor,
            workOrder: mutation.workOrder, expectedWorkOrderRevision: 0, resourceKeys: mutation.resourceKeys, saves: mutation.saves,
            tombstones: mutation.tombstones, preconditions: mutation.preconditions.filter { $0.resourceKey != mutation.saves[0].resourceKey },
            readAssertions: mutation.readAssertions, auditEvent: mutation.auditEvent, evidenceHashes: mutation.evidenceHashes)
        XCTAssertThrowsError(try AuthoritativeMutationValidator.validate(incomplete, against: validationState(for: mutation))) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .missingPrecondition(mutation.saves[0].resourceKey))
        }

        var badAudit = mutation.auditEvent
        badAudit.actorID = "different-actor"
        let unaudited = try AuthoritativeMutation(
            workspaceZone: mutation.workspaceZone, operationID: mutation.operationID, intentDigest: mutation.intentDigest, actor: mutation.actor,
            workOrder: mutation.workOrder, expectedWorkOrderRevision: 0, resourceKeys: mutation.resourceKeys, saves: mutation.saves,
            tombstones: mutation.tombstones, preconditions: mutation.preconditions, readAssertions: mutation.readAssertions, auditEvent: badAudit,
            evidenceHashes: mutation.evidenceHashes)
        XCTAssertThrowsError(try AuthoritativeMutationValidator.validate(unaudited, against: validationState(for: mutation))) { error in
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .invalidAuditEvent)
        }
    }

    func testWorkOrderMutationCannotWriteActivationOrTransferInfrastructure() throws {
        let base = try makeMutation()
        let originalKey = try XCTUnwrap(base.saves.first?.resourceKey)
        let targets = [
            AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: base.workspaceZone.workspaceID),
            ResourceKey.string("workspace-transfer-session:\(ObjectID().description)"),
        ]

        for target in targets {
            let save = AuthoritativeRecordSave(
                resourceKey: target,
                recordType: base.saves[0].recordType,
                schemaVersion: base.saves[0].schemaVersion,
                encodedRecord: base.saves[0].encodedRecord
            )
            let hostile = try AuthoritativeMutation(
                workspaceZone: base.workspaceZone,
                operationID: base.operationID,
                intentDigest: base.intentDigest,
                actor: base.actor,
                workOrder: base.workOrder,
                expectedWorkOrderRevision: base.expectedWorkOrderRevision,
                resourceKeys: base.resourceKeys,
                saves: [save],
                tombstones: [],
                preconditions: base.preconditions.map {
                    $0.resourceKey == originalKey ? .mustNotExist(target) : $0
                },
                auditEvent: base.auditEvent,
                evidenceHashes: base.evidenceHashes,
                receipt: base.receipt
            )
            XCTAssertThrowsError(
                try AuthoritativeMutationValidator.validate(
                    hostile,
                    against: validationState(for: base)
                )
            ) { error in
                XCTAssertEqual(
                    error as? AuthoritativeMutationValidationError,
                    .reservedActivationInfrastructure(target)
                )
            }
        }
    }

    func testAtomicStoreLeavesNoPartialWritesAndReturnsDeterministicReplayReceipt() async throws {
        let mutation = try makeMutation()
        let store = InMemoryAtomicMutationStore(
            currentWorkOrder: baseWorkOrder(for: mutation),
            workspaceAssertion: try XCTUnwrap(mutation.readAssertions.first)
        )
        let receipt = try await store.commit(mutation)
        XCTAssertEqual(receipt, mutation.receipt)
        let replayReceipt = try await store.commit(mutation)
        XCTAssertEqual(replayReceipt, receipt)
        let recordCount = await store.recordCount()
        XCTAssertEqual(recordCount, 5)

        let first = ResourceKey.object(ObjectID())
        let second = ResourceKey.object(ObjectID())
        let invalid = try makeMutation(operationID: ObjectID(), saveKeys: [first, second], preconditions: [.mustNotExist(first)])
        let emptyStore = InMemoryAtomicMutationStore(
            currentWorkOrder: baseWorkOrder(for: invalid),
            workspaceAssertion: try XCTUnwrap(invalid.readAssertions.first)
        )
        let countBeforeFailure = await emptyStore.recordCount()
        do {
            _ = try await emptyStore.commit(invalid)
            XCTFail("Expected an atomic validation failure")
        } catch {}
        let emptyStoreRecordCount = await emptyStore.recordCount()
        XCTAssertEqual(emptyStoreRecordCount, countBeforeFailure)
    }
}
