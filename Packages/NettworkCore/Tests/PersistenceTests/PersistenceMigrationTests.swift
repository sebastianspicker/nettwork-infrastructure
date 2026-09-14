import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Persistence

final class PersistenceMigrationTests: XCTestCase {
    func testNamespaceKeyChangesForAccountAndSessionGeneration() {
        let workspace = ObjectID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
        let first = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account-a",
            workspaceID: workspace,
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "workspace-owner",
            sessionGeneration: 1
        )
        let switchedAccount = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account-b",
            workspaceID: workspace,
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "workspace-owner",
            sessionGeneration: 1
        )
        let renewedSession = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account-a",
            workspaceID: workspace,
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "workspace-owner",
            sessionGeneration: 2
        )
        let changedZoneOwner = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account-a",
            workspaceID: workspace,
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "different-owner",
            sessionGeneration: 1
        )

        XCTAssertNotEqual(PersistenceNamespaceKey.value(for: first), PersistenceNamespaceKey.value(for: switchedAccount))
        XCTAssertNotEqual(PersistenceNamespaceKey.value(for: first), PersistenceNamespaceKey.value(for: renewedSession))
        XCTAssertNotEqual(PersistenceNamespaceKey.value(for: first), PersistenceNamespaceKey.value(for: changedZoneOwner))
        XCTAssertEqual(PersistenceNamespaceKey.value(for: first).count, 64)
        XCTAssertNotEqual(
            PersistenceNamespaceKey.storageKey(namespace: first, identity: "mirror"),
            PersistenceNamespaceKey.storageKey(namespace: switchedAccount, identity: "mirror")
        )
    }

    func testLegacyMigrationRejectsMissingBaseStateInsteadOfInventingIt() {
        let fixture = unavailableLegacyFixture(id: "20000000-0000-0000-0000-000000000001")
        let legacy = fixture.legacy

        XCTAssertThrowsError(
            try NettworkPersistenceMigration.migrate(
                legacy: legacy,
                namespace: fixture.namespace,
                envelope: nil,
                resourceKeys: [],
                dependencyOperationIDs: []
            )
        ) { error in
            XCTAssertEqual(error as? PersistenceMigrationError, .legacyBaseStateUnavailable(legacy.operationID))
        }
    }

    func testExplicitMigrationPlanPreservesUnmigratableLegacyRowForReconciliation() {
        let fixture = unavailableLegacyFixture(id: "20000000-0000-0000-0000-000000000002")
        let legacy = fixture.legacy

        XCTAssertEqual(
            NettworkPersistenceMigrationPlan.v1ToV2.migrate(
                legacy: legacy,
                namespace: fixture.namespace,
                envelope: nil,
                resourceKeys: [],
                dependencyOperationIDs: []
            ),
            .requiresReconciliation(legacy, .legacyBaseStateUnavailable(legacy.operationID))
        )
    }

    func testSwiftDataMigrationPlanDeclaresConcreteV1ToV2History() {
        XCTAssertEqual(NettworkLocalSchemaV1.versionIdentifier, .init(1, 0, 0))
        XCTAssertEqual(NettworkLocalSchemaV2.versionIdentifier, .init(2, 0, 0))
        XCTAssertEqual(NettworkLocalSchemaV3.versionIdentifier, .init(3, 0, 0))
        assertSchemaV4ThroughV9()
        XCTAssertLessThan(NettworkLocalSchemaV2.models.count, NettworkLocalSchema.models.count)
    }

    func testLegacyEvidenceCarriesOpaquePayloadWithoutInventingAnEnvelope() {
        let evidence = LegacyOutboxEvidence(
            operationID: "50000000-0000-0000-0000-000000000001",
            namespaceKey: "namespace-key",
            kind: "obsolete",
            payload: Data([1, 2]),
            baseChangeTags: Data([3]),
            createdAt: Date(timeIntervalSince1970: 0),
            attemptCount: 2,
            lastError: "legacy failure"
        )

        XCTAssertEqual(evidence.kind, "obsolete")
        XCTAssertEqual(evidence.payload, Data([1, 2]))
        XCTAssertEqual(evidence.baseChangeTags, Data([3]))
    }

    func testOutboxStatusIncludesZeroCountLifecycleStates() {
        let status = OutboxStatus.summarize([])

        XCTAssertEqual(status.totalCount, 0)
        XCTAssertEqual(status.queueDepth, 0)
        XCTAssertEqual(status.acceptedHistoryCount, 0)
        XCTAssertEqual(
            status.countsByState,
            [
                .pending: 0,
                .uploading: 0,
                .retryScheduled: 0,
                .conflicted: 0,
                .poisoned: 0,
                .accepted: 0,
            ])
        XCTAssertNil(status.oldestQueuedAt)
        XCTAssertNil(status.nextRetryAt)
    }

    func testOutboxStatusSeparatesQueueDepthFromAcceptedHistory() throws {
        let retryAt = Date(timeIntervalSince1970: 200)
        let queued = try makeOperation(
            id: ObjectID(UUID(uuidString: "30000000-0000-0000-0000-000000000001")!),
            state: .retryScheduled,
            createdAt: Date(timeIntervalSince1970: 100),
            nextRetryAt: retryAt
        )
        let accepted = try makeOperation(
            id: ObjectID(UUID(uuidString: "30000000-0000-0000-0000-000000000002")!),
            state: .accepted,
            createdAt: Date(timeIntervalSince1970: 50),
            nextRetryAt: nil
        )

        let status = OutboxStatus.summarize([accepted, queued])

        XCTAssertEqual(status.totalCount, 2)
        XCTAssertEqual(status.queueDepth, 1)
        XCTAssertEqual(status.acceptedHistoryCount, 1)
        XCTAssertEqual(status.countsByState[.retryScheduled], 1)
        XCTAssertEqual(status.countsByState[.accepted], 1)
        XCTAssertEqual(status.oldestQueuedAt, queued.createdAt)
        XCTAssertEqual(status.nextRetryAt, retryAt)
    }

    func testLocalMirrorVisibilityDefaultsToLiveAndStagedStateIsDurableDTO() throws {
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "account-a",
            workspaceID: ObjectID(), zoneName: "workspace-zone", zoneOwnerRecordName: "owner", sessionGeneration: 1
        )
        let live = LocalMirrorRecord(
            namespace: namespace, resourceKey: .string("live"), recordType: "NettworkLocation", schemaVersion: 1,
            payload: Data([1]), systemFields: Data([2]), changeTag: "tag", isTombstone: false,
            serverModifiedAt: .distantPast, verifiedAt: .distantPast
        )
        XCTAssertEqual(live.visibility, .live)
        let transferID = ObjectID()
        let commit = WorkspaceActivationCommit(transferID: transferID, memberCount: 1, rollingDigest: "digest")
        let staged = LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .active(commit: commit))
        XCTAssertEqual(staged.lifecycle, .active(commit: commit))
    }

    private func makeOperation(id: ObjectID, state: OutboxState, createdAt: Date, nextRetryAt: Date?) throws -> OutboxOperation {
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account-a",
            workspaceID: ObjectID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!),
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "workspace-owner",
            sessionGeneration: 1
        )
        let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32))
        let workOrder = WorkOrder(
            id: ObjectID(UUID(uuidString: "40000000-0000-0000-0000-000000000001")!), kind: .connect, title: "Status fixture", creatorID: "account-a",
            intentDigest: digest)
        let audit = AuditEvent(
            id: ObjectID(UUID(uuidString: "40000000-0000-0000-0000-000000000002")!),
            operationID: id,
            actorID: "account-a",
            affectedObjectIDs: [],
            workOrderID: workOrder.id,
            occurredAt: createdAt,
            result: .accepted,
            installationID: "installation-a",
            sessionID: "session-a",
            sessionGeneration: 1
        )
        let mutation = try AuthoritativeMutation(
            workspaceZone: namespace.workspaceZone,
            operationID: id,
            intentDigest: digest,
            actor: ActorInstallationSnapshot(
                actorID: "account-a", installationID: "installation-a", sessionID: "session-a", sessionGeneration: 1, capturedAt: createdAt),
            workOrder: workOrder,
            expectedWorkOrderRevision: 0,
            resourceKeys: [],
            saves: [],
            tombstones: [],
            preconditions: [],
            auditEvent: audit,
            evidenceHashes: []
        )
        let envelope = ExecutionEnvelope(
            mutation: mutation,
            accountContext: AccountContext(namespace: namespace, databaseScope: .ownerPrivate, sharePermission: .owner, verifiedAt: createdAt),
            actorContext: ActorContext(cloudKitUserRecordName: "account-a", role: .administrator, installationID: "installation-a", sessionGeneration: 1),
            clientTime: createdAt,
            ticket: nil,
            notes: nil,
            baseSnapshots: [:]
        )
        return OutboxOperation(
            operationID: id,
            namespace: namespace,
            envelope: envelope,
            resourceKeys: [],
            dependencyOperationIDs: [],
            createdAt: createdAt,
            state: state,
            nextRetryAt: nextRetryAt
        )
    }

    private func unavailableLegacyFixture(id: String) -> (legacy: LegacyOutboxPayload, namespace: PersistenceNamespace) {
        let legacy = LegacyOutboxPayload(
            operationID: ObjectID(UUID(uuidString: id)!), kind: "obsolete", payload: Data([1]), baseChangeTags: Data(),
            createdAt: Date(timeIntervalSince1970: 0), attemptCount: 0)
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "account-a",
            workspaceID: ObjectID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!), zoneName: "workspace-zone",
            zoneOwnerRecordName: "workspace-owner", sessionGeneration: 1)
        return (legacy, namespace)
    }
}

func assertSchemaV4ThroughV9() {
    XCTAssertEqual(NettworkLocalSchemaV4.versionIdentifier, .init(4, 0, 0))
    XCTAssertEqual(NettworkLocalSchemaV5.versionIdentifier, .init(5, 0, 0))
    XCTAssertEqual(NettworkLocalSchemaV6.versionIdentifier, .init(6, 0, 0))
    XCTAssertEqual(NettworkLocalSchemaV7.versionIdentifier, .init(7, 0, 0))
    XCTAssertEqual(NettworkLocalSchemaV8.versionIdentifier, .init(8, 0, 0))
    XCTAssertEqual(NettworkLocalSchemaV9.versionIdentifier, .init(9, 0, 0))
    XCTAssertEqual(NettworkLocalSchemaMigrationPlan.schemas.count, 9)
    XCTAssertEqual(NettworkLocalSchemaMigrationPlan.stages.count, 8)
}
