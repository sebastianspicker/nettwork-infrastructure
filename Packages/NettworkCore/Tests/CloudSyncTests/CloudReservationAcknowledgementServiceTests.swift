import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudReservationAcknowledgementServiceTests: XCTestCase {
    func testAcknowledgementCommitsSameStatusRevisionAndExactReceipt() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let exactRecords = InMemoryExactRecordReader(records: fixture.exactRecords())
        let mutations = RecordingMutationRepository()
        let service = CloudReservationAcknowledgementService(
            exactRecords: exactRecords,
            mutations: mutations
        )

        let result = try await service.acknowledge(
            reservedWorkOrder: fixture.reservedWorkOrder,
            account: fixture.account,
            actor: fixture.actor,
            actorSnapshot: fixture.actorSnapshot,
            operationID: fixture.operationID,
            expiresAt: fixture.expiresAt,
            policyVersion: "test-policy-v1"
        )

        let committedMutation = await mutations.committedMutation()
        let committed = try XCTUnwrap(committedMutation)
        let acknowledgement = try XCTUnwrap(result.workOrder.reservation?.acknowledgedByCloudKit)
        XCTAssertEqual(result.workOrder.status, .reserved)
        XCTAssertEqual(result.workOrder.revision, fixture.reservedWorkOrder.revision + 1)
        XCTAssertEqual(acknowledgement.systemFields, fixture.serverRecord.exactPrecondition.systemFields)
        XCTAssertEqual(acknowledgement.changeTag, fixture.serverRecord.exactPrecondition.changeTag)
        XCTAssertEqual(acknowledgement.acknowledgedAt, fixture.serverRecord.serverModifiedAt)
        XCTAssertEqual(result.receipt, committed.receipt)
        XCTAssertEqual(result.receipt.workspaceZone, fixture.account.namespace.workspaceZone)
        XCTAssertEqual(result.receipt.operationID, fixture.operationID)
        let expectedIntentDigest = try XCTUnwrap(fixture.reservedWorkOrder.intentDigest)
        XCTAssertEqual(result.receipt.intentDigest, expectedIntentDigest)
        XCTAssertEqual(result.receipt.auditEventID, committed.auditEvent.id)
    }

    func testAcknowledgementRejectsStaleServerRecordWithoutCommit() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let staleRecord = fixture.serverRecord(withServerModifiedAt: fixture.actorSnapshot.capturedAt.addingTimeInterval(1))
        let mutations = RecordingMutationRepository()
        let service = CloudReservationAcknowledgementService(
            exactRecords: InMemoryExactRecordReader(records: fixture.exactRecords(workOrder: staleRecord)),
            mutations: mutations
        )

        do {
            _ = try await service.acknowledge(
                reservedWorkOrder: fixture.reservedWorkOrder,
                account: fixture.account,
                actor: fixture.actor,
                actorSnapshot: fixture.actorSnapshot,
                operationID: fixture.operationID,
                expiresAt: fixture.expiresAt,
                policyVersion: "test-policy-v1"
            )
            XCTFail("Expected stale server record rejection")
        } catch {
            XCTAssertEqual(error as? CloudReservationAcknowledgementError, .invalidAcknowledgementWindow)
        }

        let commitCount = await mutations.commitCount()
        XCTAssertEqual(commitCount, 0)
    }

    func testAcknowledgementRejectsTamperedServerRecordWithoutCommit() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let tamperedRecord = try fixture.serverRecord(for: fixture.workOrder(title: "Tampered server title"))
        let mutations = RecordingMutationRepository()
        let service = CloudReservationAcknowledgementService(
            exactRecords: InMemoryExactRecordReader(records: fixture.exactRecords(workOrder: tamperedRecord)),
            mutations: mutations
        )

        do {
            _ = try await service.acknowledge(
                reservedWorkOrder: fixture.reservedWorkOrder,
                account: fixture.account,
                actor: fixture.actor,
                actorSnapshot: fixture.actorSnapshot,
                operationID: fixture.operationID,
                expiresAt: fixture.expiresAt,
                policyVersion: "test-policy-v1"
            )
            XCTFail("Expected tampered server record rejection")
        } catch {
            XCTAssertEqual(error as? CloudReservationAcknowledgementError, .recordMismatch)
        }

        let commitCount = await mutations.commitCount()
        XCTAssertEqual(commitCount, 0)
    }

    func testAcknowledgementRejectsActorSnapshotMismatchWithoutCommit() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let mismatchedSnapshot = ActorInstallationSnapshot(
            actorID: "different-actor",
            installationID: fixture.actor.installationID,
            sessionID: fixture.actorSnapshot.sessionID,
            sessionGeneration: fixture.actor.sessionGeneration,
            capturedAt: fixture.actorSnapshot.capturedAt
        )
        let mutations = RecordingMutationRepository()
        let service = CloudReservationAcknowledgementService(
            exactRecords: InMemoryExactRecordReader(records: fixture.exactRecords()),
            mutations: mutations
        )

        do {
            _ = try await service.acknowledge(
                reservedWorkOrder: fixture.reservedWorkOrder,
                account: fixture.account,
                actor: fixture.actor,
                actorSnapshot: mismatchedSnapshot,
                operationID: fixture.operationID,
                expiresAt: fixture.expiresAt,
                policyVersion: "test-policy-v1"
            )
            XCTFail("Expected actor snapshot mismatch")
        } catch {
            XCTAssertEqual(error as? CloudReservationAcknowledgementServiceError, .actorSnapshotMismatch)
        }

        let commitCount = await mutations.commitCount()
        XCTAssertEqual(commitCount, 0)
    }

    func testExactStateProviderReturnsExactPreconditionsAndCurrentWorkOrder() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let mutation = try fixture.acknowledgementMutation()
        let provider = CloudExactAuthoritativeMutationStateProvider(
            reader: InMemoryExactRecordReader(records: fixture.exactRecords()),
            account: fixture.account
        )

        let state = try await provider.state(for: mutation)

        XCTAssertEqual(
            state.knownRecords,
            [
                fixture.workOrderKey: fixture.serverRecord.exactPrecondition,
                fixture.sentinelKey: fixture.sentinelRecord.exactPrecondition,
            ])
        XCTAssertEqual(state.currentWorkOrder, fixture.reservedWorkOrder)
    }

    func testExactStateProviderRejectsWrongWorkspace() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let wrongWorkspace = AuthoritativeWorkspaceZone(
            workspaceID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!),
            containerIdentifier: fixture.account.namespace.containerIdentifier,
            zoneName: "nettwork.workspace.wrong",
            zoneOwnerRecordName: fixture.actor.cloudKitUserRecordName
        )
        let mutation = try fixture.acknowledgementMutation(workspaceZone: wrongWorkspace)
        let provider = CloudExactAuthoritativeMutationStateProvider(
            reader: InMemoryExactRecordReader(records: fixture.exactRecords()),
            account: fixture.account
        )

        do {
            _ = try await provider.state(for: mutation)
            XCTFail("Expected workspace mismatch")
        } catch {
            XCTAssertEqual(error as? CloudExactMutationStateError, .workspaceMismatch)
        }
    }

    func testExactStateProviderRejectsMismatchedReturnedSnapshotIdentity() async throws {
        let fixture = try AcknowledgementServiceFixture.make()
        let mutation = try fixture.acknowledgementMutation()
        let wrongKey = ResourceKey.object(
            ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000098")!)
        )
        let mismatched = CloudExactRecordSnapshot(
            workspaceZone: fixture.serverRecord.workspaceZone,
            resourceKey: wrongKey,
            recordType: fixture.serverRecord.recordType,
            schemaVersion: fixture.serverRecord.schemaVersion,
            payload: fixture.serverRecord.payload,
            exactPrecondition: fixture.serverRecord.exactPrecondition,
            serverModifiedAt: fixture.serverRecord.serverModifiedAt
        )
        let provider = CloudExactAuthoritativeMutationStateProvider(
            reader: MismatchedExactRecordReader(snapshot: mismatched),
            account: fixture.account
        )

        do {
            _ = try await provider.state(for: mutation)
            XCTFail("Expected returned snapshot identity mismatch")
        } catch {
            XCTAssertEqual(
                error as? CloudExactMutationStateError,
                .returnedSnapshotMismatch(fixture.workOrderKey)
            )
        }
    }
}

private actor MismatchedExactRecordReader: CloudExactRecordReading {
    let snapshot: CloudExactRecordSnapshot

    init(snapshot: CloudExactRecordSnapshot) {
        self.snapshot = snapshot
    }

    func exactRecord(
        for resourceKey: ResourceKey,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot? {
        snapshot
    }
}

private actor InMemoryExactRecordReader: CloudExactRecordReading {
    private let records: [ResourceKey: CloudExactRecordSnapshot]

    init(records: [ResourceKey: CloudExactRecordSnapshot]) {
        self.records = records
    }

    func exactRecord(
        for resourceKey: ResourceKey,
        in workspaceZone: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot? {
        guard let record = records[resourceKey], record.workspaceZone == workspaceZone else {
            return nil
        }
        return record
    }
}

private actor RecordingMutationRepository: AuthoritativeMutationRepository {
    private var mutations: [AuthoritativeMutation] = []

    func commit(_ mutation: AuthoritativeMutation) async throws -> OperationReceipt {
        mutations.append(mutation)
        return mutation.receipt
    }

    func commitCount() -> Int { mutations.count }

    func committedMutation() -> AuthoritativeMutation? { mutations.last }
}

private struct AcknowledgementServiceFixture {
    let account: AccountContext
    let actor: ActorContext
    let actorSnapshot: ActorInstallationSnapshot
    let operationID: ObjectID
    let expiresAt: Date
    let reservedWorkOrder: WorkOrder
    let serverRecord: CloudExactRecordSnapshot
    let sentinelRecord: CloudExactRecordSnapshot

    var workOrderKey: ResourceKey { .object(reservedWorkOrder.id) }
    var sentinelKey: ResourceKey {
        AuthoritativeActivationMutation.bootstrapSentinelResourceKey(
            for: account.namespace.workspaceID
        )
    }

    static func make() throws -> AcknowledgementServiceFixture {
        let workspaceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let workOrderID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let reservationID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let resourceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_030)
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "owner-record", workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID), zoneOwnerRecordName: "owner-record", sessionGeneration: 7)
        let account = AccountContext(namespace: namespace, databaseScope: .ownerPrivate, sharePermission: .owner, verifiedAt: capturedAt)
        let actor = ActorContext(
            cloudKitUserRecordName: "owner-record", role: .technician, installationID: "test-installation", sessionGeneration: namespace.sessionGeneration)
        let actorSnapshot = ActorInstallationSnapshot(
            actorID: actor.cloudKitUserRecordName, installationID: actor.installationID, sessionID: "test-session", sessionGeneration: actor.sessionGeneration,
            capturedAt: capturedAt)
        let resourceKeys: Set<ResourceKey> = [.object(resourceID)]
        let operations: [PlannedWorkOperation] = [
            .device(resourceKey: .object(resourceID), description: "Install edge port")
        ]
        let intentDigest = try CanonicalWorkIntent(
            workOrderID: workOrderID, kind: .device, creatorID: actor.cloudKitUserRecordName, ticket: "CHG-123", notes: "Install the new edge port",
            operations: operations, resourceKeys: resourceKeys, evidenceHashes: []
        ).digest()
        let workOrder = WorkOrder(
            id: workOrderID, kind: .device, title: "Install edge port", status: .reserved, creatorID: actor.cloudKitUserRecordName, ticket: "CHG-123",
            notes: "Install the new edge port", plannedOperations: operations, intentDigest: intentDigest,
            reservation: WorkOrderReservation(id: reservationID, ownerID: actor.cloudKitUserRecordName, resourceKeys: resourceKeys))
        let serverRecord = try makeServerRecord(
            for: workOrder, workspaceZone: namespace.workspaceZone, serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let sentinelRecord = try makeSentinelRecord(workspaceZone: namespace.workspaceZone)
        return AcknowledgementServiceFixture(
            account: account, actor: actor, actorSnapshot: actorSnapshot, operationID: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000014")!),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_300), reservedWorkOrder: workOrder, serverRecord: serverRecord, sentinelRecord: sentinelRecord)
    }

    func workOrder(title: String) -> WorkOrder {
        var updated = reservedWorkOrder
        updated.title = title
        return updated
    }

    func serverRecord(for workOrder: WorkOrder) throws -> CloudExactRecordSnapshot {
        try Self.makeServerRecord(
            for: workOrder,
            workspaceZone: account.namespace.workspaceZone,
            serverModifiedAt: serverRecord.serverModifiedAt
        )
    }

    func serverRecord(withServerModifiedAt serverModifiedAt: Date) -> CloudExactRecordSnapshot {
        CloudExactRecordSnapshot(
            workspaceZone: serverRecord.workspaceZone,
            resourceKey: serverRecord.resourceKey,
            recordType: serverRecord.recordType,
            schemaVersion: serverRecord.schemaVersion,
            payload: serverRecord.payload,
            exactPrecondition: serverRecord.exactPrecondition,
            serverModifiedAt: serverModifiedAt
        )
    }

    func exactRecords(
        workOrder: CloudExactRecordSnapshot? = nil
    ) -> [ResourceKey: CloudExactRecordSnapshot] {
        [
            workOrderKey: workOrder ?? serverRecord,
            sentinelKey: sentinelRecord,
        ]
    }

    func acknowledgementMutation(
        workspaceZone: AuthoritativeWorkspaceZone? = nil
    ) throws -> AuthoritativeMutation {
        let acknowledgement = try CloudReservationAcknowledgementVerifier.verify(
            reservedWorkOrder: reservedWorkOrder,
            serverRecord: serverRecord,
            account: account,
            actor: actor,
            expiresAt: expiresAt,
            observedAt: actorSnapshot.capturedAt
        )
        let acknowledgedWorkOrder = try WorkOrderStateMachine.acknowledgeReservation(
            reservedWorkOrder,
            acknowledgement: acknowledgement,
            observedAt: actorSnapshot.capturedAt
        )
        let selectedZone = workspaceZone ?? account.namespace.workspaceZone
        let selectedSentinel =
            selectedZone == account.namespace.workspaceZone
            ? sentinelRecord
            : try Self.makeSentinelRecord(workspaceZone: selectedZone)
        let assertion = AuthoritativeReadAssertion(
            resourceKey: selectedSentinel.resourceKey,
            recordType: selectedSentinel.recordType,
            schemaVersion: selectedSentinel.schemaVersion,
            encodedRecord: selectedSentinel.payload,
            precondition: selectedSentinel.exactPrecondition
        )
        return try AuthoritativeWorkOrderMutationFactory.make(
            operationID: operationID,
            workspaceZone: selectedZone,
            actor: actorSnapshot,
            currentWorkOrder: reservedWorkOrder,
            updatedWorkOrder: acknowledgedWorkOrder,
            state: AuthoritativeMutationState(
                knownRecords: [
                    workOrderKey: serverRecord.exactPrecondition,
                    assertion.resourceKey: assertion.precondition,
                ],
                currentWorkOrder: reservedWorkOrder
            ),
            readAssertions: [assertion],
            source: .interactive,
            policyVersion: "test-policy-v1"
        )
    }

    private static func makeServerRecord(
        for workOrder: WorkOrder,
        workspaceZone: AuthoritativeWorkspaceZone,
        serverModifiedAt: Date
    ) throws -> CloudExactRecordSnapshot {
        try acknowledgementServerRecord(for: workOrder, workspaceZone: workspaceZone, serverModifiedAt: serverModifiedAt)
    }

    private static func makeSentinelRecord(
        workspaceZone: AuthoritativeWorkspaceZone
    ) throws -> CloudExactRecordSnapshot {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(
            for: workspaceZone.workspaceID
        )
        let payload = try CloudDeterministicCoding.encode(
            CloudWorkspaceRecord(
                workspaceID: workspaceZone.workspaceID,
                zoneName: workspaceZone.zoneName,
                zoneOwnerRecordName: workspaceZone.zoneOwnerRecordName,
                lifecycle: .active(
                    commit: WorkspaceActivationCommit(
                        transferID: ObjectID(),
                        memberCount: 0,
                        rollingDigest: "active"
                    ))
            ))
        return CloudExactRecordSnapshot(
            workspaceZone: workspaceZone,
            resourceKey: key,
            recordType: CloudRecordNaming.workspaceRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: payload,
            exactPrecondition: ExactRecordPrecondition(
                systemFields: Data("workspace-system-fields".utf8),
                changeTag: "workspace-active"
            ),
            serverModifiedAt: Date(timeIntervalSince1970: 1_699_999_900)
        )
    }
}
