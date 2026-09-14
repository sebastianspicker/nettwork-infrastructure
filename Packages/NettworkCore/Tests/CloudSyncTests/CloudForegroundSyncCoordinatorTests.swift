import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudForegroundSyncCoordinatorTests: XCTestCase {
    func testFakeTransportAppliesOnlyCompleteVerifiedBatch() async throws {
        let fixture = Fixture()
        let mirror = FakeMirror()
        let session = CloudSessionLifecycle(store: mirror)
        try await session.activate(fixture.account)
        let transport = FakeTransport(batch: CloudChangeBatch(records: [fixture.validRecord], newState: Data("next-state".utf8)))
        let coordinator = makeCoordinator(session: session, transport: transport, mirror: mirror, account: fixture.account)

        let receipt = await coordinator.synchronizeForeground()
        let appliedCount = await mirror.appliedRecords.count
        let appliedState = await mirror.appliedState
        let persistedState = await transport.persistedAppliedState

        XCTAssertTrue(receipt.failures.isEmpty)
        XCTAssertEqual(appliedCount, 1)
        XCTAssertEqual(appliedState, Data("next-state".utf8))
        XCTAssertEqual(persistedState, Data("next-state".utf8))
    }

    func testMalformedFakeRecordIsQuarantinedWithoutPartialApply() async throws {
        let fixture = Fixture()
        let mirror = FakeMirror()
        let session = CloudSessionLifecycle(store: mirror)
        try await session.activate(fixture.account)
        let malformed = CloudRecordEnvelope(
            resourceKey: .object(ObjectID()),
            workspaceID: fixture.workspaceID,
            recordType: "UnregisteredPeerRecord",
            payload: fixture.validRecord.payload,
            systemFields: fixture.validRecord.systemFields,
            changeTag: fixture.validRecord.changeTag
        )
        let transport = FakeTransport(batch: CloudChangeBatch(records: [fixture.validRecord, malformed], newState: Data("must-not-commit".utf8)))
        let coordinator = makeCoordinator(session: session, transport: transport, mirror: mirror, account: fixture.account)

        let receipt = await coordinator.synchronizeForeground()
        let appliedCount = await mirror.appliedRecords.count
        let appliedState = await mirror.appliedState
        let quarantinedCount = await mirror.quarantined.count

        XCTAssertEqual(receipt.failures.first?.category, .malformedRemoteRecord)
        XCTAssertEqual(appliedCount, 0)
        XCTAssertTrue(appliedState.isEmpty)
        XCTAssertEqual(quarantinedCount, 1)
    }

    func testEnvelopeIdentityAndQuarantineEvidenceAreDeterministicAndBounded() throws {
        let fixture = Fixture()
        let first = fixture.validRecord
        let second = CloudRecordEnvelope(
            id: ObjectID(),
            resourceKey: first.resourceKey,
            workspaceID: fixture.workspaceID,
            recordType: first.recordType,
            payload: Data(repeating: 1, count: QuarantinedCloudRecord.maximumPreservedEnvelopeBytes * 2),
            systemFields: first.systemFields,
            changeTag: first.changeTag
        )

        XCTAssertEqual(first.id, second.id)
        let quarantine = try QuarantinedCloudRecord(envelope: second, reason: "fault injection")
        XCTAssertLessThanOrEqual(quarantine.boundedEnvelope.count, QuarantinedCloudRecord.maximumPreservedEnvelopeBytes)
    }

    func testLostResponseReceiptResolutionRejectsMismatchedIntent() throws {
        let fixture = Fixture()
        let operationID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 1, count: 32))
        let expected = OperationReceipt(
            workspaceZone: fixture.account.namespace.workspaceZone, operationID: operationID, intentDigest: digest, auditEventID: ObjectID())
        let mismatchedDigest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 2, count: 32))
        let observed = OperationReceipt(
            workspaceZone: fixture.account.namespace.workspaceZone, operationID: operationID, intentDigest: mismatchedDigest,
            auditEventID: expected.auditEventID)

        XCTAssertEqual(LostReceiptRecovery.resolve(expected: expected, observed: nil), .retry)
        XCTAssertEqual(LostReceiptRecovery.resolve(expected: expected, observed: observed), .securityMismatch(observed))
    }

    func testSameResourceRaceBatchIsWithheldAndQuarantined() async throws {
        let fixture = Fixture()
        let mirror = FakeMirror()
        let session = CloudSessionLifecycle(store: mirror)
        try await session.activate(fixture.account)
        var competingRecord = fixture.validRecord
        competingRecord.changeTag = "competing-change-tag"
        let transport = FakeTransport(batch: CloudChangeBatch(records: [fixture.validRecord, competingRecord], newState: Data("race-state".utf8)))
        let coordinator = makeCoordinator(session: session, transport: transport, mirror: mirror, account: fixture.account)

        let receipt = await coordinator.synchronizeForeground()
        let appliedCount = await mirror.appliedRecords.count
        let quarantinedCount = await mirror.quarantined.count

        XCTAssertEqual(receipt.failures.first?.category, .malformedRemoteRecord)
        XCTAssertEqual(appliedCount, 0)
        XCTAssertEqual(quarantinedCount, 2)
    }

    func testSessionRevocationDuringFetchWithholdsRemoteBatch() async throws {
        let fixture = Fixture()
        let mirror = FakeMirror()
        let session = CloudSessionLifecycle(store: mirror)
        try await session.activate(fixture.account)
        let transport = RevokingTransport(
            session: session,
            batch: CloudChangeBatch(records: [fixture.validRecord], newState: Data("must-not-apply".utf8))
        )
        let coordinator = makeCoordinator(session: session, transport: transport, mirror: mirror, account: fixture.account)

        let receipt = await coordinator.synchronizeForeground()

        let appliedCount = await mirror.appliedRecords.count
        let appliedState = await mirror.appliedState
        let activeLease = await session.activeLease()
        XCTAssertEqual(receipt.failures.first?.category, .accountUnavailable)
        XCTAssertEqual(appliedCount, 0)
        XCTAssertTrue(appliedState.isEmpty)
        XCTAssertNil(activeLease)
    }

    func testCandidateSnapshotRejectsTombstoneResurrection() async throws {
        let fixture = Fixture()
        let candidate = VerifiedCloudRecord(envelope: fixture.validRecord)
        let validator = TombstoneAwareCloudRemoteReferenceValidator()

        do {
            try await validator.validate(
                candidate: [candidate],
                against: CloudRemoteMirrorSnapshot(
                    existingResourceKeys: Set([fixture.validRecord.resourceKey]), tombstonedResourceKeys: Set([fixture.validRecord.resourceKey])),
                namespace: fixture.account.namespace
            )
            XCTFail("Expected a tombstone-resurrection rejection")
        } catch let error as CloudRemoteReferenceValidationError {
            XCTAssertEqual(error.invalidResourceKeys, Set([fixture.validRecord.resourceKey]))
        }
    }

    func testCompositeReferenceValidatorAcceptsOutOfOrderIPAMCandidateDependencies() async throws {
        let fixture = Fixture()
        let vrfID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let prefixID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let vrf = VRF(id: vrfID, name: "production")
        let prefix = Prefix(id: prefixID, vrfID: vrfID, cidr: "10.0.0.0/24")!
        let validator = CompositeCloudRemoteReferenceValidator()

        try await validator.validate(
            candidate: [
                VerifiedCloudRecord(envelope: fixture.record(for: prefix, recordType: "NettworkPrefix")),
                VerifiedCloudRecord(envelope: fixture.record(for: vrf, recordType: "NettworkVRF")),
            ],
            against: CloudRemoteMirrorSnapshot(existingResourceKeys: [], tombstonedResourceKeys: []),
            namespace: fixture.account.namespace
        )
    }

    func testCompositeReferenceValidatorRejectsPersistedDependentOfCandidateDeletion() async throws {
        let fixture = Fixture()
        let vrfID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!)
        let prefixID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        let vrfKey = ResourceKey.object(vrfID)
        let prefixKey = ResourceKey.object(prefixID)
        let deletion = CloudRecordEnvelope(
            resourceKey: vrfKey,
            workspaceID: fixture.workspaceID,
            recordType: "NettworkVRF",
            payload: Data(),
            systemFields: Data("system-fields".utf8),
            changeTag: "delete-tag",
            isDeleted: true
        )

        do {
            try await CompositeCloudRemoteReferenceValidator().validate(
                candidate: [VerifiedCloudRecord(envelope: deletion)],
                against: CloudRemoteMirrorSnapshot(
                    existingResourceKeys: [vrfKey, prefixKey],
                    tombstonedResourceKeys: [],
                    referencesByResourceKey: [prefixKey: [vrfKey]],
                    hasCompleteReferenceIndex: true
                ),
                namespace: fixture.account.namespace
            )
            XCTFail("Expected the retained prefix reference to reject the VRF deletion")
        } catch let error as CloudRemoteReferenceValidationError {
            XCTAssertEqual(error.invalidResourceKeys, [prefixKey])
        }
    }

    func testCompositeReferenceValidatorLinksWorkOrderAuditAndReceipt() async throws {
        let fixture = Fixture()
        let workOrderID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000030")!)
        let auditID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
        let operationID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000032")!)
        let digest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 3, count: 32))
        let workOrder = WorkOrder(id: workOrderID, kind: .connect, title: "Install")
        let audit = AuditEvent(id: auditID, operationID: operationID, actorID: "owner", affectedObjectIDs: [], workOrderID: workOrderID, result: .accepted)
        let receipt = OperationReceipt(
            workspaceZone: fixture.account.namespace.workspaceZone, operationID: operationID, intentDigest: digest, auditEventID: auditID)

        try await CompositeCloudRemoteReferenceValidator().validate(
            candidate: [
                VerifiedCloudRecord(envelope: fixture.record(for: receipt, recordType: CloudRecordNaming.receiptRecordType)),
                VerifiedCloudRecord(envelope: fixture.record(for: audit, recordType: CloudRecordNaming.auditRecordType)),
                VerifiedCloudRecord(envelope: fixture.record(for: workOrder, recordType: CloudRecordNaming.workOrderRecordType)),
            ],
            against: CloudRemoteMirrorSnapshot(existingResourceKeys: [], tombstonedResourceKeys: []),
            namespace: fixture.account.namespace
        )
    }
}

private struct Fixture {
    let workspaceID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let recordID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    var account: AccountContext {
        AccountContext(
            namespace: PersistenceNamespace(
                containerIdentifier: "iCloud.example.nettwork",
                cloudKitAccountRecordName: "owner-record",
                workspaceID: workspaceID,
                zoneName: CloudRecordNaming.zoneName(for: workspaceID),
                zoneOwnerRecordName: "owner-record",
                sessionGeneration: 1
            ),
            databaseScope: .ownerPrivate,
            sharePermission: .owner,
            verifiedAt: .now
        )
    }

    var validRecord: CloudRecordEnvelope {
        let key = ResourceKey.object(recordID)
        return CloudRecordEnvelope(
            id: recordID,
            recordName: CloudRecordNaming.recordName(for: key, workspaceID: workspaceID),
            resourceKey: key,
            workspaceID: workspaceID,
            recordType: CloudRecordNaming.workOrderRecordType,
            payload: Data("valid-payload".utf8),
            systemFields: Data("opaque-system-fields".utf8),
            changeTag: "change-tag"
        )
    }

    func record<T: Encodable & Identifiable>(for value: T, recordType: String) throws -> CloudRecordEnvelope where T.ID == ObjectID {
        let key = ResourceKey.object(value.id)
        return CloudRecordEnvelope(
            resourceKey: key,
            workspaceID: workspaceID,
            recordType: recordType,
            payload: try CloudDeterministicCoding.encode(value),
            systemFields: Data("opaque-system-fields".utf8),
            changeTag: "change-tag"
        )
    }

    func record(for value: OperationReceipt, recordType: String) throws -> CloudRecordEnvelope {
        CloudRecordEnvelope(
            resourceKey: value.id,
            workspaceID: workspaceID,
            recordType: recordType,
            payload: try CloudDeterministicCoding.encode(value),
            systemFields: Data("opaque-system-fields".utf8),
            changeTag: "change-tag"
        )
    }
}

private func makeCoordinator(
    session: CloudSessionLifecycle,
    transport: any CloudRecordTransport,
    mirror: any CloudMirrorStore,
    account: AccountContext
) -> CloudForegroundSyncCoordinator {
    let outbox = EmptyOutbox()
    let actor = ActorContext(
        cloudKitUserRecordName: account.namespace.cloudKitAccountRecordName,
        role: .administrator,
        installationID: "foreground-sync-test-installation",
        sessionGeneration: account.namespace.sessionGeneration
    )
    return CloudForegroundSyncCoordinator(
        session: session,
        transport: transport,
        mirror: mirror,
        membershipVerifier: FakeForegroundMembershipVerifier(event: .activated(account)),
        outboxReplayer: CloudOutboxReplayer(
            transport: transport,
            outbox: outbox,
            conflicts: EmptyConflictResolver()
        ),
        actorContextProvider: FakeForegroundActorContextProvider(actor: actor),
        mutationStateProvider: EmptyMutationStateProvider()
    )
}

private actor FakeTransport: CloudRecordTransport, CloudAppliedChangeStatePersisting {
    let batch: CloudChangeBatch
    private(set) var persistedAppliedState: Data?
    init(batch: CloudChangeBatch) { self.batch = batch }
    func fetchChanges() async throws -> CloudChangeBatch { batch }
    func persistAppliedChangeState(_ state: Data) async throws { persistedAppliedState = state }
    func saveAtomically(_ mutation: AtomicCloudMutation) async throws -> CloudSaveResult {
        let receiptRecord = mutation.records.first { $0.recordType == CloudRecordNaming.receiptRecordType }!
        return .accepted(receipt: try CloudDeterministicCoding.decode(OperationReceipt.self, from: receiptRecord.payload))
    }
}

private actor RevokingTransport: CloudRecordTransport {
    let session: CloudSessionLifecycle
    let batch: CloudChangeBatch

    init(session: CloudSessionLifecycle, batch: CloudChangeBatch) {
        self.session = session
        self.batch = batch
    }

    func fetchChanges() async throws -> CloudChangeBatch {
        await session.invalidateCurrentSession()
        return batch
    }

    func saveAtomically(_: AtomicCloudMutation) async throws -> CloudSaveResult {
        throw CloudTransportFailure(
            SyncFailure(category: .accountUnavailable, message: "session revoked"),
            possiblyCommitted: false
        )
    }
}

private actor FakeMirror: CloudMirrorStore {
    var appliedRecords: [VerifiedCloudRecord] = []
    var appliedState = Data()
    var quarantined: [QuarantinedCloudRecord] = []

    func open(namespace: PersistenceNamespace) async throws {}
    func close(namespace: PersistenceNamespace) async {}
    func purgeEphemeralState() async {}
    func validateRemoteReferences(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws {}
    func applyVerifiedBatch(_ records: [VerifiedCloudRecord], syncState: Data, namespace: PersistenceNamespace) async throws {
        appliedRecords = records
        appliedState = syncState
    }
    func quarantine(_ record: QuarantinedCloudRecord, namespace: PersistenceNamespace) async throws { quarantined.append(record) }
    func syncStatus(namespace: PersistenceNamespace) async throws -> CloudMirrorStatus {
        CloudMirrorStatus(quarantineCount: quarantined.count, lastSuccessfulServerContact: appliedRecords.isEmpty ? nil : .now)
    }
}

private actor FakeForegroundMembershipVerifier: CloudForegroundMembershipVerifying {
    let event: CloudSessionEvent

    init(event: CloudSessionEvent) { self.event = event }

    func verifyForegroundMembership() async throws -> CloudSessionEvent { event }
}

private struct FakeForegroundActorContextProvider: CloudForegroundActorContextProvider {
    let actor: ActorContext

    func actorContext(for _: AccountContext) async throws -> ActorContext { actor }
}

private actor EmptyOutbox: MutationOutbox {
    func enqueue(_: OutboxOperation) async throws {}
    func operations(in _: PersistenceNamespace) async throws -> [OutboxOperation] { [] }
    func operationsReady(at _: Date, in _: PersistenceNamespace) async throws -> [OutboxOperation] { [] }
    func status(in _: PersistenceNamespace) async throws -> OutboxStatus {
        OutboxStatus(totalCount: 0, queueDepth: 0, acceptedHistoryCount: 0, countsByState: [:], oldestQueuedAt: nil, nextRetryAt: nil)
    }
    func recordAttempt(operationID _: ObjectID, at _: Date, namespace _: PersistenceNamespace) async throws {}
    func recordFailure(operationID _: ObjectID, failure _: SyncFailure, nextRetryAt _: Date?, poison _: Bool, namespace _: PersistenceNamespace) async throws {}
    func recordAcceptance(operationID _: ObjectID, receipt _: OperationReceipt, namespace _: PersistenceNamespace) async throws {}
}

private actor EmptyConflictResolver: ConflictResolver {
    func capture(_: ReconciliationCase) async throws {}
    func unresolvedCases(in _: PersistenceNamespace) async throws -> [ReconciliationCase] { [] }
}

private struct EmptyMutationStateProvider: AuthoritativeMutationStateProviding {
    func state(for _: AuthoritativeMutation) async throws -> AuthoritativeMutationState {
        AuthoritativeMutationState()
    }
}
