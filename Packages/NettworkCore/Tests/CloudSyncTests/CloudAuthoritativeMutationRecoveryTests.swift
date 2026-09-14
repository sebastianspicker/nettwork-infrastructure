import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

extension CloudAuthoritativeMutationRepositoryTests {
    func testRepositoryRejectsChangedReadAssertionBeforeTransport() async throws {
        let fixture = try MutationCommitFixture.make()
        let assertionKey = ResourceKey.object(ObjectID())
        let expected = ExactRecordPrecondition(systemFields: Data([1]), changeTag: "read-v1")
        let assertion = AuthoritativeReadAssertion(
            resourceKey: assertionKey,
            recordType: "NettworkPort",
            schemaVersion: CloudRecordNaming.schemaVersion,
            encodedRecord: Data("{}".utf8),
            precondition: expected
        )
        let mutation = try fixture.mutation(with: assertion)
        var changedState = fixture.state
        changedState.knownRecords[assertionKey] = ExactRecordPrecondition(systemFields: Data([9]), changeTag: "read-v2")
        let transport = CommitTransport(result: .accepted(receipt: mutation.receipt))
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: CommitStateProvider(state: changedState)
        )

        do {
            _ = try await repository.commit(mutation)
            XCTFail("Expected a changed read dependency to be rejected")
        } catch {
            XCTAssertEqual(error as? AuthoritativeMutationValidationError, .preconditionConflict(assertionKey))
        }
        let calls = await transport.saveCallCount()
        XCTAssertEqual(calls, 0)
    }

    func testRepositoryRecoversOrdinaryMutationAfterLostAcceptedResponse() async throws {
        let fixture = try MutationCommitFixture.make()
        let transport = CommitTransport(
            result: .retryableFailure(SyncFailure(category: .network, message: "lost response")),
            receiptResults: [nil, fixture.mutation.receipt]
        )
        let repository = CloudAuthoritativeMutationRepository(
            transport: transport,
            stateProvider: CommitStateProvider(state: fixture.state)
        )

        let receipt = try await repository.commit(fixture.mutation)
        XCTAssertEqual(receipt, fixture.mutation.receipt)
        let saveCalls = await transport.saveCallCount()
        XCTAssertEqual(saveCalls, 1)
    }

    func testOutboxReplayRecoversAcceptedWriteAfterResponseIsLost() async throws {
        let fixture = try MutationCommitFixture.make()
        let account = account(for: fixture.mutation.workspaceZone)
        let actor = ActorContext(
            cloudKitUserRecordName: account.namespace.cloudKitAccountRecordName,
            role: .administrator,
            installationID: fixture.mutation.actor.installationID,
            sessionGeneration: account.namespace.sessionGeneration
        )
        let operation = outboxOperation(for: fixture.mutation, account: account)
        let outbox = DurableOutbox(operations: [operation])
        let transport = CommitTransport(
            result: .retryableFailure(SyncFailure(category: .network, message: "response dropped")),
            receiptResults: [fixture.mutation.receipt],
            saveError: CloudTransportFailure(
                SyncFailure(category: .network, message: "accepted before response loss"),
                possiblyCommitted: true
            )
        )
        let replayer = CloudOutboxReplayer(
            transport: transport,
            receiptLookup: transport,
            outbox: outbox,
            conflicts: NoopConflictResolver()
        )

        let result = await replayer.replay(
            namespace: account.namespace,
            account: account,
            actor: actor,
            stateProvider: CommitStateProvider(state: fixture.state),
            now: .distantPast
        )

        XCTAssertEqual(result.uploadedOperationIDs, [operation.operationID])
        XCTAssertTrue(result.failures.isEmpty)
        let savedCalls = await transport.saveCallCount()
        let persistedOperation = await outbox.operation(id: operation.operationID)
        XCTAssertEqual(savedCalls, 1)
        let persisted = try XCTUnwrap(persistedOperation)
        XCTAssertEqual(persisted.state, .accepted)
        XCTAssertEqual(persisted.receipt, fixture.mutation.receipt)
    }

    func testOutboxDependencyPlannerSerializesSameResourceOperations() throws {
        let fixture = try MutationCommitFixture.make()
        let account = account(for: fixture.mutation.workspaceZone)
        let first = outboxOperation(for: fixture.mutation, account: account, createdAt: .distantPast)
        let second = outboxOperation(
            for: fixture.mutation,
            account: account,
            operationID: ObjectID(),
            createdAt: .distantPast.addingTimeInterval(1)
        )
        let plan = OutboxDependencyPlanner.plan([second, first], at: .distantPast)

        XCTAssertEqual(plan.ordered.map(\.operationID), [first.operationID, second.operationID])
        XCTAssertTrue(plan.deferredOperationIDs.isEmpty)
        XCTAssertTrue(plan.cyclicOperationIDs.isEmpty)
    }

    func testOutboxReplayAfterRestartReplaysDurableOfflineOperation() async throws {
        let fixture = try MutationCommitFixture.make()
        let account = account(for: fixture.mutation.workspaceZone)
        let actor = ActorContext(
            cloudKitUserRecordName: account.namespace.cloudKitAccountRecordName,
            role: .administrator,
            installationID: fixture.mutation.actor.installationID,
            sessionGeneration: account.namespace.sessionGeneration
        )
        let operation = outboxOperation(for: fixture.mutation, account: account, createdAt: .distantPast)
        let outbox = DurableOutbox(operations: [operation])
        let unavailableTransport = CommitTransport(
            result: .retryableFailure(SyncFailure(category: .network, message: "offline"))
        )
        let initialReplayer = CloudOutboxReplayer(
            transport: unavailableTransport,
            outbox: outbox,
            conflicts: NoopConflictResolver()
        )

        let initial = await initialReplayer.replay(
            namespace: account.namespace,
            account: account,
            actor: actor,
            stateProvider: CommitStateProvider(state: fixture.state),
            now: .distantPast
        )
        XCTAssertTrue(initial.uploadedOperationIDs.isEmpty)
        let initialSaveCalls = await unavailableTransport.saveCallCount()
        XCTAssertEqual(initialSaveCalls, 1)

        let restartedTransport = CommitTransport(result: .accepted(receipt: fixture.mutation.receipt))
        let restartedReplayer = CloudOutboxReplayer(
            transport: restartedTransport,
            outbox: outbox,
            conflicts: NoopConflictResolver()
        )
        let recovered = await restartedReplayer.replay(
            namespace: account.namespace,
            account: account,
            actor: actor,
            stateProvider: CommitStateProvider(state: fixture.state),
            now: .distantPast.addingTimeInterval(15)
        )

        XCTAssertEqual(recovered.uploadedOperationIDs, [operation.operationID])
        let restartedSaveCalls = await restartedTransport.saveCallCount()
        let acceptedOperation = await outbox.operation(id: operation.operationID)
        let attemptedOperationIDs = await outbox.attemptedOperationIDs()
        XCTAssertEqual(restartedSaveCalls, 1)
        let accepted = try XCTUnwrap(acceptedOperation)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(attemptedOperationIDs, [operation.operationID, operation.operationID])
    }
}
