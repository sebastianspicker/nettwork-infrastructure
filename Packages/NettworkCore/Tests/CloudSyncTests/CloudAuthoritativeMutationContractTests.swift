import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

extension CloudAuthoritativeMutationRepositoryTests {
    func testGenericRecordAssetIsRejectedBeforeAtomicTransport() async throws {
        let fixture = try MutationCommitFixture.make()
        let bytes = Data("archive-bytes".utf8)
        let asset = try CloudRecordAssetDescriptor(
            id: ObjectID(),
            fieldName: "archiveAsset",
            sha256: CloudRecordAssetDescriptor.sha256(for: bytes),
            contentType: "application/octet-stream",
            byteCount: bytes.count,
            storage: .inline(bytes)
        )
        let save = try XCTUnwrap(fixture.mutation.saves.first)
        let mutation = try AuthoritativeMutation(
            workspaceZone: fixture.mutation.workspaceZone,
            operationID: fixture.mutation.operationID,
            intentDigest: fixture.mutation.intentDigest,
            actor: fixture.mutation.actor,
            workOrder: fixture.mutation.workOrder,
            expectedWorkOrderRevision: fixture.mutation.expectedWorkOrderRevision,
            resourceKeys: fixture.mutation.resourceKeys,
            saves: [
                AuthoritativeRecordSave(
                    resourceKey: save.resourceKey,
                    recordType: save.recordType,
                    schemaVersion: save.schemaVersion,
                    encodedRecord: save.encodedRecord,
                    recordAsset: asset
                )
            ],
            tombstones: fixture.mutation.tombstones,
            preconditions: fixture.mutation.preconditions,
            readAssertions: fixture.mutation.readAssertions,
            auditEvent: fixture.mutation.auditEvent,
            evidenceHashes: fixture.mutation.evidenceHashes,
            receipt: fixture.mutation.receipt,
            encodedWorkOrder: fixture.mutation.encodedWorkOrder,
            encodedAuditEvent: fixture.mutation.encodedAuditEvent,
            encodedReceipt: fixture.mutation.encodedReceipt
        )
        let transport = CommitTransport(result: .accepted(receipt: mutation.receipt))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: CommitStateProvider(state: fixture.state)
        )

        do {
            _ = try await repository.commit(mutation)
            XCTFail("Expected an unbound generic asset to be rejected")
        } catch {
            XCTAssertEqual(error as? AtomicCloudMutationValidationError, .invalidRecordAsset(save.resourceKey))
        }
        let saveCallCount = await transport.saveCallCount()
        XCTAssertEqual(saveCallCount, 0)
    }

    func testRepositoryRejectsAcceptedReceiptThatWasNotTheSubmittedReceipt() async throws {
        let fixture = try MutationCommitFixture.make()
        let wrong = OperationReceipt(
            workspaceZone: fixture.mutation.workspaceZone,
            operationID: ObjectID(),
            intentDigest: fixture.mutation.intentDigest,
            auditEventID: fixture.mutation.auditEvent.id
        )
        let repository = CloudAuthoritativeMutationRepository(
            transport: CommitTransport(result: .accepted(receipt: wrong)),
            stateProvider: CommitStateProvider(state: fixture.state)
        )

        do {
            _ = try await repository.commit(fixture.mutation)
            XCTFail("Expected receipt mismatch")
        } catch {
            XCTAssertEqual(error as? CloudAuthoritativeCommitError, .returnedReceiptMismatch)
        }
    }

    func testRepositoryEncodesUnchangedReadAssertionWithItsExactPrecondition() async throws {
        let fixture = try MutationCommitFixture.make()
        let assertionKey = ResourceKey.object(ObjectID())
        let exact = ExactRecordPrecondition(systemFields: Data([5, 4, 3]), changeTag: "read-v2")
        let assertion = AuthoritativeReadAssertion(
            resourceKey: assertionKey,
            recordType: "NettworkPort",
            schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: Data("{\"label\":\"unchanged\"}".utf8),
            precondition: exact
        )
        let mutation = try fixture.mutation(with: assertion)
        var state = fixture.state
        state.knownRecords[assertionKey] = exact
        let transport = CommitTransport(result: .accepted(receipt: mutation.receipt))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: CommitStateProvider(state: state)
        )

        let receipt = try await repository.commit(mutation)
        XCTAssertEqual(receipt, mutation.receipt)
        let savedMutation = await transport.lastSavedMutation()
        let encoded = try XCTUnwrap(savedMutation)
        let record = try XCTUnwrap(encoded.records.first { $0.resourceKey == assertionKey })
        XCTAssertEqual(record.recordType, assertion.recordType)
        XCTAssertEqual(record.schemaVersion, assertion.schemaVersion)
        XCTAssertEqual(record.payload, assertion.encodedRecord)
        XCTAssertEqual(record.systemFields, exact.systemFields)
        XCTAssertEqual(record.changeTag, exact.changeTag)
        XCTAssertEqual(record.writeMode, .assertionPreserving)
        XCTAssertNil(record.recordAsset)
        XCTAssertTrue(
            encoded.preconditions.contains(
                .exact(
                    recordName: CloudRecordNaming.recordName(for: assertionKey, workspaceID: mutation.workspaceZone.workspaceID),
                    systemFields: exact.systemFields,
                    changeTag: exact.changeTag
                )))
        XCTAssertFalse(mutation.resourceKeys.contains(assertionKey))
        XCTAssertFalse(mutation.auditEvent.affectedResourceKeys.contains(assertionKey))
    }

    func testBusinessSaveWithoutAssetUsesExplicitClearWriteMode() throws {
        let fixture = try MutationCommitFixture.make()
        let encoded = try CloudMutationEncoder.encode(fixture.mutation, against: fixture.state)
        let businessRecord = try XCTUnwrap(encoded.records.first { $0.resourceKey == fixture.mutation.saves[0].resourceKey })

        XCTAssertEqual(businessRecord.writeMode, .businessSave)
        XCTAssertNil(businessRecord.recordAsset)
    }

    func testAssertionPreservingWriteRequiresExactPrecondition() throws {
        let fixture = try MutationCommitFixture.make()
        let key = ResourceKey.object(ObjectID())
        let record = CloudRecordEnvelope(
            resourceKey: key,
            workspaceID: fixture.mutation.workspaceZone.workspaceID,
            recordType: "NettworkPort",
            payload: Data("unchanged".utf8),
            writeMode: .assertionPreserving,
            systemFields: Data(),
            changeTag: ""
        )
        let mutation = AtomicCloudMutation(
            operationID: ObjectID(),
            workspaceZone: fixture.mutation.workspaceZone,
            records: [record],
            preconditions: [.mustNotExist(recordName: record.recordName)]
        )

        XCTAssertThrowsError(try AtomicCloudMutationValidator.validate(mutation)) { error in
            XCTAssertEqual(
                error as? AtomicCloudMutationValidationError,
                .assertionPreservationRequiresExactPrecondition(key)
            )
        }
    }

    func testAssertionPreservingWriteRejectsDeletedRecord() throws {
        let fixture = try MutationCommitFixture.make()
        let key = ResourceKey.object(ObjectID())
        let record = CloudRecordEnvelope(
            resourceKey: key,
            workspaceID: fixture.mutation.workspaceZone.workspaceID,
            recordType: "NettworkPort",
            payload: Data("unchanged".utf8),
            writeMode: .assertionPreserving,
            systemFields: Data([1]),
            changeTag: "read-v1",
            isDeleted: true
        )
        let mutation = AtomicCloudMutation(
            operationID: ObjectID(),
            workspaceZone: fixture.mutation.workspaceZone,
            records: [record],
            preconditions: [.exact(recordName: record.recordName, systemFields: Data([1]), changeTag: "read-v1")]
        )

        XCTAssertThrowsError(try AtomicCloudMutationValidator.validate(mutation)) { error in
            XCTAssertEqual(
                error as? AtomicCloudMutationValidationError,
                .assertionPreservationRequiresExactPrecondition(key)
            )
        }
    }

    func testOrdinaryAtomicMutationAcceptsTheConservativeRecordBoundary() throws {
        let fixture = try MutationCommitFixture.make()
        let mutation = atomicMutation(
            recordCount: AtomicCloudMutation.maximumBusinessRecordsPerOperation,
            workspaceZone: fixture.mutation.workspaceZone
        )

        XCTAssertNoThrow(try AtomicCloudMutationValidator.validate(mutation))
    }

    func testOrdinaryAtomicMutationRejectsOneRecordBeyondTheConservativeBoundary() throws {
        let fixture = try MutationCommitFixture.make()
        let mutation = atomicMutation(
            recordCount: AtomicCloudMutation.maximumBusinessRecordsPerOperation + 1,
            workspaceZone: fixture.mutation.workspaceZone
        )

        XCTAssertThrowsError(try AtomicCloudMutationValidator.validate(mutation)) { error in
            XCTAssertEqual(error as? AtomicCloudMutationValidationError, .atomicBatchTooLarge)
        }
    }

    private func atomicMutation(
        recordCount: Int,
        workspaceZone: AuthoritativeWorkspaceZone
    ) -> AtomicCloudMutation {
        let records = (0..<recordCount).map { index in
            CloudRecordEnvelope(
                resourceKey: .string("atomic-boundary:\(index)"),
                workspaceID: workspaceZone.workspaceID,
                recordType: "NettworkAtomicBoundaryFixture",
                payload: Data("{\"index\":\(index)}".utf8),
                systemFields: Data(),
                changeTag: ""
            )
        }
        return AtomicCloudMutation(
            operationID: ObjectID(),
            workspaceZone: workspaceZone,
            records: records,
            preconditions: records.map { .mustNotExist(recordName: $0.recordName) }
        )
    }
}
