import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class AuthoritativeActivationRepositoryTests: XCTestCase {
    func testRepositoryEncodesActivationByteStablyWithCanonicalRegisteredTypes() async throws {
        let fixture = try CloudActivationFixture.make()
        let transport = ActivationCommitTransport(result: .accepted(receipt: fixture.mutation.receipt))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        let receipt = try await repository.commit(fixture.mutation)
        XCTAssertEqual(receipt, fixture.mutation.receipt)
        let savedMutation = await transport.lastSavedMutation()
        let submitted = try XCTUnwrap(savedMutation)
        let reencoded = try CloudActivationMutationEncoder.encode(fixture.mutation, against: fixture.state)
        XCTAssertEqual(submitted, reencoded)
        XCTAssertEqual(
            submitted.records.first { $0.resourceKey == fixture.sentinel.resourceKey }?.recordType,
            CloudRecordNaming.workspaceRecordType
        )
        XCTAssertEqual(
            submitted.records.first { $0.resourceKey == fixture.businessSave.resourceKey }?.recordType,
            CloudRecordNaming.floorPlanAssetBindingRecordType
        )
        XCTAssertEqual(
            submitted.records.first {
                $0.recordType == CloudRecordNaming.workOrderRecordType
            }?.writeMode,
            .assertionPreserving
        )
        XCTAssertEqual(
            submitted.records.first {
                $0.resourceKey == fixture.businessSave.resourceKey
            }?.writeMode,
            .businessSave
        )
        XCTAssertTrue(
            submitted.preconditions.contains(
                .exact(
                    recordName: CloudRecordNaming.recordName(
                        for: fixture.sentinel.resourceKey,
                        workspaceID: fixture.mutation.workspaceZone.workspaceID
                    ),
                    systemFields: fixture.sentinelExact.systemFields,
                    changeTag: fixture.sentinelExact.changeTag
                )))
    }

    func testRepositoryRejectsInvalidActivationBeforeTransport() async throws {
        let fixture = try CloudActivationFixture.make()
        let transport = ActivationCommitTransport(result: .accepted(receipt: fixture.mutation.receipt))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        var wrongAudit = fixture.mutation.auditEvent
        wrongAudit.actorID = "attacker"
        let invalidAudit = try fixture.replacing(auditEvent: wrongAudit)
        let missingPrecondition = try fixture.replacing(
            preconditions: fixture.mutation.preconditions.filter { $0.resourceKey != fixture.businessSave.resourceKey }
        )
        let duplicateSave = try fixture.replacing(saves: fixture.mutation.saves + [fixture.businessSave])
        let wrongReceipt = try fixture.replacing(
            receipt: OperationReceipt(
                workspaceZone: AuthoritativeWorkspaceZone(
                    workspaceID: ObjectID(),
                    containerIdentifier: fixture.mutation.workspaceZone.containerIdentifier,
                    zoneName: "wrong-zone",
                    zoneOwnerRecordName: fixture.mutation.workspaceZone.zoneOwnerRecordName
                ),
                operationID: fixture.mutation.operationID,
                intentDigest: fixture.mutation.intentDigest,
                auditEventID: fixture.mutation.auditEvent.id
            ))

        for invalid in [invalidAudit, missingPrecondition, duplicateSave, wrongReceipt] {
            do {
                _ = try await repository.commit(invalid)
                XCTFail("Expected hostile activation input to be rejected")
            } catch {}
        }
        let invalidTransportCalls = await transport.saveCallCount()
        XCTAssertEqual(invalidTransportCalls, 0)
    }

    func testRepositoryRejectsConflictFromWrongWorkspaceZone() async throws {
        let fixture = try CloudActivationFixture.make()
        let wrongWorkspace = ObjectID()
        let wrongNamespace = PersistenceNamespace(
            containerIdentifier: fixture.mutation.workspaceZone.containerIdentifier,
            cloudKitAccountRecordName: "owner",
            workspaceID: wrongWorkspace,
            zoneName: CloudRecordNaming.zoneName(for: wrongWorkspace),
            zoneOwnerRecordName: "owner",
            sessionGeneration: 1
        )
        let wrongConflict = ReconciliationCase(
            namespace: wrongNamespace,
            operationID: fixture.mutation.operationID,
            resourceKeys: fixture.mutation.resourceKeys,
            reason: .serverRecordChanged,
            base: [:],
            intended: [:],
            current: [:],
            detectedAt: .distantPast
        )
        let transport = ActivationCommitTransport(result: .conflict(wrongConflict))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        do {
            _ = try await repository.commit(fixture.mutation)
            XCTFail("Expected an out-of-zone conflict to be rejected")
        } catch let error as CloudAuthoritativeCommitError {
            guard case let .permanent(failure) = error else {
                return XCTFail("Expected a permanent security failure")
            }
            XCTAssertEqual(failure.category, .security)
        }
    }

    func testRepositoryReturnsMatchingRecoveredReceiptBeforeRetryingActivation() async throws {
        let fixture = try CloudActivationFixture.make()
        let transport = ActivationCommitTransport(
            result: .retryableFailure(SyncFailure(category: .network, message: "lost response")),
            receiptLookupResults: [fixture.mutation.receipt]
        )
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        let receipt = try await repository.commit(fixture.mutation)
        XCTAssertEqual(receipt, fixture.mutation.receipt)
        let savedCalls = await transport.saveCallCount()
        XCTAssertEqual(savedCalls, 0)
    }

    func testRepositoryRecoversMatchingReceiptAfterRetryableActivationResponse() async throws {
        let fixture = try CloudActivationFixture.make()
        let transport = ActivationCommitTransport(
            result: .retryableFailure(SyncFailure(category: .network, message: "lost response")),
            receiptLookupResults: [nil, fixture.mutation.receipt]
        )
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        let receipt = try await repository.commit(fixture.mutation)
        XCTAssertEqual(receipt, fixture.mutation.receipt)
        let savedCalls = await transport.saveCallCount()
        let receiptCalls = await transport.receiptLookupCallCount()
        XCTAssertEqual(savedCalls, 1)
        XCTAssertEqual(receiptCalls, 2)
    }

    func testRepositoryRecoversMatchingExactReceiptAfterAmbiguousActivationResponse() async throws {
        let fixture = try CloudActivationFixture.make()
        let transport = ActivationCommitTransport(
            result: .retryableFailure(SyncFailure(category: .network, message: "unused")),
            exactRecordResults: [nil, fixture.exactReceiptSnapshot],
            saveError: CloudTransportFailure(
                SyncFailure(category: .network, message: "connection dropped"),
                possiblyCommitted: true
            )
        )
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        let receipt = try await repository.commit(fixture.mutation)
        XCTAssertEqual(receipt, fixture.mutation.receipt)
        let savedCalls = await transport.saveCallCount()
        XCTAssertEqual(savedCalls, 1)
    }

    func testRepositoryRejectsMismatchedRecoveredActivationReceiptBeforeSubmitting() async throws {
        let fixture = try CloudActivationFixture.make()
        let wrongReceipt = OperationReceipt(
            workspaceZone: fixture.mutation.workspaceZone,
            operationID: fixture.mutation.operationID,
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32)),
            auditEventID: fixture.mutation.auditEvent.id
        )
        let transport = ActivationCommitTransport(
            result: .accepted(receipt: fixture.mutation.receipt),
            receiptLookupResults: [wrongReceipt]
        )
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: ActivationCommitStateProvider(state: fixture.state)
        )

        do {
            _ = try await repository.commit(fixture.mutation)
            XCTFail("Expected recovered receipt mismatch")
        } catch {
            XCTAssertEqual(error as? CloudAuthoritativeCommitError, .returnedReceiptMismatch)
        }
        let savedCalls = await transport.saveCallCount()
        XCTAssertEqual(savedCalls, 0)
    }

    func testExactStateProviderRejectsWrongMutationZoneBeforeTransport() async throws {
        let fixture = try CloudActivationFixture.make()
        let namespace = PersistenceNamespace(
            containerIdentifier: fixture.mutation.workspaceZone.containerIdentifier,
            cloudKitAccountRecordName: "owner",
            workspaceID: fixture.mutation.workspaceZone.workspaceID,
            zoneName: fixture.mutation.workspaceZone.zoneName,
            zoneOwnerRecordName: fixture.mutation.workspaceZone.zoneOwnerRecordName,
            sessionGeneration: fixture.mutation.actor.sessionGeneration
        )
        let account = AccountContext(
            namespace: namespace,
            databaseScope: .ownerPrivate,
            sharePermission: .owner,
            verifiedAt: .distantPast
        )
        let transport = ActivationCommitTransport(result: .accepted(receipt: fixture.mutation.receipt))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: CloudExactAuthoritativeMutationStateProvider(
                reader: EmptyActivationReader(),
                account: account
            )
        )
        let wrongZone = AuthoritativeWorkspaceZone(
            workspaceID: ObjectID(),
            containerIdentifier: namespace.containerIdentifier,
            zoneName: "wrong-zone",
            zoneOwnerRecordName: namespace.zoneOwnerRecordName
        )
        let wrongMutation = try AuthoritativeActivationMutation(
            workspaceZone: wrongZone,
            operationID: fixture.mutation.operationID,
            intentDigest: fixture.mutation.intentDigest,
            actor: fixture.mutation.actor,
            saves: fixture.mutation.saves,
            tombstones: fixture.mutation.tombstones,
            preconditions: fixture.mutation.preconditions,
            auditEvent: fixture.mutation.auditEvent,
            receipt: fixture.mutation.receipt
        )

        do {
            _ = try await repository.commit(wrongMutation)
            XCTFail("Expected a workspace mismatch")
        } catch {
            XCTAssertEqual(error as? CloudExactMutationStateError, .workspaceMismatch)
        }
        let wrongZoneTransportCalls = await transport.saveCallCount()
        XCTAssertEqual(wrongZoneTransportCalls, 0)
    }
}

private actor ActivationCommitTransport: CloudRecordTransport, CloudReceiptLookupTransport, CloudExactRecordReading {
    let result: CloudSaveResult
    let saveError: CloudTransportFailure?
    private var savedMutation: AtomicCloudMutation?
    private var calls = 0
    private var receiptLookupResults: [OperationReceipt?]
    private var exactRecordResults: [CloudExactRecordSnapshot?]
    private var receiptCalls = 0

    init(
        result: CloudSaveResult,
        receiptLookupResults: [OperationReceipt?] = [],
        exactRecordResults: [CloudExactRecordSnapshot?] = [],
        saveError: CloudTransportFailure? = nil
    ) {
        self.result = result
        self.receiptLookupResults = receiptLookupResults
        self.exactRecordResults = exactRecordResults
        self.saveError = saveError
    }

    func fetchChanges() async throws -> CloudChangeBatch {
        CloudChangeBatch(records: [], newState: Data())
    }

    func saveAtomically(_ mutation: AtomicCloudMutation) async throws -> CloudSaveResult {
        calls += 1
        savedMutation = mutation
        if let saveError { throw saveError }
        return result
    }

    func lastSavedMutation() -> AtomicCloudMutation? {
        savedMutation
    }

    func saveCallCount() -> Int {
        calls
    }

    func receipt(operationID _: ObjectID, in _: AuthoritativeWorkspaceZone) async throws -> OperationReceipt? {
        receiptCalls += 1
        guard !receiptLookupResults.isEmpty else { return nil }
        return receiptLookupResults.removeFirst()
    }

    func exactRecord(
        for _: ResourceKey,
        in _: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot? {
        guard !exactRecordResults.isEmpty else { return nil }
        return exactRecordResults.removeFirst()
    }

    func receiptLookupCallCount() -> Int {
        receiptCalls
    }
}

private struct EmptyActivationReader: CloudExactRecordReading {
    func exactRecord(
        for _: ResourceKey,
        in _: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot? {
        nil
    }
}

private actor ActivationCommitStateProvider: AuthoritativeMutationStateProviding {
    let state: AuthoritativeActivationMutationState

    init(state: AuthoritativeActivationMutationState) {
        self.state = state
    }

    func state(for _: AuthoritativeMutation) async throws -> AuthoritativeMutationState {
        AuthoritativeMutationState()
    }

    func state(for _: AuthoritativeActivationMutation) async throws -> AuthoritativeActivationMutationState {
        state
    }
}

private struct CloudActivationFixture {
    let mutation: AuthoritativeActivationMutation
    let state: AuthoritativeActivationMutationState
    let sentinel: AuthoritativeRecordSave
    let sentinelExact: ExactRecordPrecondition
    let businessSave: AuthoritativeRecordSave

    var exactReceiptSnapshot: CloudExactRecordSnapshot {
        CloudExactRecordSnapshot(
            workspaceZone: mutation.workspaceZone,
            resourceKey: mutation.receipt.id,
            recordType: CloudRecordNaming.receiptRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: mutation.encodedReceipt,
            exactPrecondition: ExactRecordPrecondition(
                systemFields: Data([9]),
                changeTag: "receipt-v1"
            ),
            serverModifiedAt: .distantPast
        )
    }

    static func make() throws -> CloudActivationFixture {
        let workspaceID = ObjectID()
        let zone = AuthoritativeWorkspaceZone(
            workspaceID: workspaceID, containerIdentifier: "iCloud.example.nettwork", zoneName: CloudRecordNaming.zoneName(for: workspaceID),
            zoneOwnerRecordName: "owner")
        let actor = ActorInstallationSnapshot(
            actorID: "owner", installationID: "test-installation", sessionID: "test-session", sessionGeneration: 1, capturedAt: .distantPast)
        let operationID = ObjectID()
        let intent = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 5, count: 32))
        let sentinelPayload = try CloudDeterministicCoding.encode(
            CloudWorkspaceRecord(
                workspaceID: workspaceID, zoneName: zone.zoneName, zoneOwnerRecordName: zone.zoneOwnerRecordName,
                lifecycle: .active(commit: .init(transferID: ObjectID(), memberCount: 1, rollingDigest: "active-workspace"))))
        let sentinel = AuthoritativeRecordSave(
            resourceKey: AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspaceID), recordType: CloudRecordNaming.workspaceRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion, encodedRecord: sentinelPayload)
        let floorID = ObjectID()
        let assetBytes = Data("floor-plan-jpeg".utf8)
        let asset = try CloudRecordAssetDescriptor(
            id: ObjectID(), fieldName: "floorPlanAsset", sha256: CloudRecordAssetDescriptor.sha256(for: assetBytes), contentType: "image/jpeg",
            byteCount: assetBytes.count, storage: .inline(assetBytes))
        let planned = try PlannedFloorPlanAsset(floorID: floorID, assetMetadata: asset.metadata)
        let workOrder = WorkOrder(
            kind: .floorPlan, title: "Bind floor plan", status: .completed, creatorID: actor.actorID, plannedOperations: [.floorPlan(.bindAsset(planned))],
            intentDigest: intent)
        let auditID = AuditEvent.deterministicID(for: operationID)
        let binding = try FloorPlanAssetBindingRecord(
            floorID: floorID, workOrderID: workOrder.id, assetMetadata: asset.metadata, intentDigest: intent, operationID: operationID, auditEventID: auditID,
            boundAt: actor.capturedAt)
        let businessSave = AuthoritativeRecordSave(
            resourceKey: binding.resourceKey, recordType: CloudRecordNaming.floorPlanAssetBindingRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: try CloudDeterministicCoding.encode(binding), recordAsset: asset)
        let saves = [sentinel, businessSave]
        let touched = Set(saves.map(\.resourceKey))
        let audit = AuditEvent(
            id: auditID, operationID: operationID, actorID: actor.actorID,
            affectedObjectIDs: touched.compactMap {
                guard case let .object(id) = $0 else { return nil }
                return id
            }.sorted(), workOrderID: workOrder.id, occurredAt: actor.capturedAt, result: .accepted, installationID: actor.installationID,
            sessionID: actor.sessionID, sessionGeneration: actor.sessionGeneration, affectedResourceKeys: touched.sorted(),
            changes: saves.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord) }.sorted { $0.resourceKey < $1.resourceKey },
            policyVersion: "activation-v1")
        let receipt = OperationReceipt(workspaceZone: zone, operationID: operationID, intentDigest: intent, auditEventID: audit.id)
        let sentinelExact = ExactRecordPrecondition(systemFields: Data([2]), changeTag: "bootstrap-v1")
        let workOrderExact = ExactRecordPrecondition(systemFields: Data([3]), changeTag: "work-order-v1")
        let workOrderAssertion = AuthoritativeReadAssertion(
            resourceKey: .object(workOrder.id), recordType: CloudRecordNaming.workOrderRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: try CloudDeterministicCoding.encode(workOrder), precondition: workOrderExact)
        let mutation = try AuthoritativeActivationMutation(
            workspaceZone: zone, operationID: operationID, intentDigest: intent, actor: actor, saves: saves, tombstones: [],
            preconditions: [
                .exactSystemFields(sentinel.resourceKey, sentinelExact), .mustNotExist(businessSave.resourceKey),
                .exactSystemFields(workOrderAssertion.resourceKey, workOrderExact), .mustNotExist(.object(audit.id)), .mustNotExist(receipt.id),
            ], readAssertions: [workOrderAssertion], auditEvent: audit, receipt: receipt)
        return CloudActivationFixture(
            mutation: mutation,
            state: state(sentinel: sentinel, exact: sentinelExact, workOrderAssertion: workOrderAssertion, workOrderExact: workOrderExact),
            sentinel: sentinel, sentinelExact: sentinelExact, businessSave: businessSave)
    }

    private static func state(
        sentinel: AuthoritativeRecordSave,
        exact sentinelExact: ExactRecordPrecondition,
        workOrderAssertion: AuthoritativeReadAssertion,
        workOrderExact: ExactRecordPrecondition
    ) -> AuthoritativeActivationMutationState {
        AuthoritativeActivationMutationState(
            knownRecords: [sentinel.resourceKey: sentinelExact, workOrderAssertion.resourceKey: workOrderExact],
            currentRecords: [
                workOrderAssertion.resourceKey: .init(
                    recordType: workOrderAssertion.recordType, schemaVersion: workOrderAssertion.schemaVersion,
                    encodedRecord: workOrderAssertion.encodedRecord, precondition: workOrderExact)
            ], currentSentinel: .init(recordType: sentinel.recordType, schemaVersion: sentinel.schemaVersion, encodedRecord: sentinel.encodedRecord))
    }

    func replacing(
        saves: [AuthoritativeRecordSave]? = nil,
        preconditions: [MutationPrecondition]? = nil,
        auditEvent: AuditEvent? = nil,
        receipt: OperationReceipt? = nil
    ) throws -> AuthoritativeActivationMutation {
        try AuthoritativeActivationMutation(
            workspaceZone: mutation.workspaceZone,
            operationID: mutation.operationID,
            intentDigest: mutation.intentDigest,
            actor: mutation.actor,
            saves: saves ?? mutation.saves,
            tombstones: mutation.tombstones,
            preconditions: preconditions ?? mutation.preconditions,
            readAssertions: mutation.readAssertions,
            auditEvent: auditEvent ?? mutation.auditEvent,
            receipt: receipt
        )
    }
}
