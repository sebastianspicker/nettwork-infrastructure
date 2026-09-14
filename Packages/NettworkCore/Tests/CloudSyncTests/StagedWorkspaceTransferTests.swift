import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class StagedWorkspaceTransferTests: XCTestCase {
    func testMarkerFirstAndMarkerLastRemainInvisibleUntilCompleteVerifiedSetExists() throws {
        let fixture = try Fixture.make()
        let markerFirst = try CloudStagedTransferLifecycle.derive(
            records: [fixture.sessionRecord, fixture.memberRecord, fixture.workspaceEmptyRecord], namespace: fixture.namespace
        )
        XCTAssertEqual(markerFirst.lifecycle, .empty(epoch: fixture.session.epoch))

        let markerLast = try CloudStagedTransferLifecycle.derive(
            records: [fixture.memberRecord, fixture.workspaceActiveRecord], namespace: fixture.namespace
        )
        XCTAssertEqual(markerLast.lifecycle, .empty(epoch: 0))

        let active = try CloudStagedTransferLifecycle.derive(
            records: [fixture.memberRecord, fixture.sessionRecord, fixture.workspaceActiveRecord], namespace: fixture.namespace
        )
        XCTAssertEqual(
            active.lifecycle,
            .active(
                commit: WorkspaceActivationCommit(
                    transferID: fixture.session.transferID,
                    memberCount: fixture.session.cursor,
                    rollingDigest: fixture.session.rollingDigest
                )))
    }

    func testTamperedMemberDigestFailsClosed() throws {
        let fixture = try Fixture.make()
        let tampered = LocalMirrorRecord(
            namespace: fixture.namespace, resourceKey: fixture.memberRecord.resourceKey,
            recordType: fixture.memberRecord.recordType, schemaVersion: fixture.memberRecord.schemaVersion,
            payload: Data("tampered".utf8), systemFields: Data([1]), changeTag: "tag",
            isTombstone: false, visibility: .staged(transferID: fixture.session.transferID),
            serverModifiedAt: .distantPast, verifiedAt: .distantPast
        )
        let result = try CloudStagedTransferLifecycle.derive(
            records: [tampered, fixture.sessionRecord, fixture.workspaceActiveRecord], namespace: fixture.namespace
        )
        XCTAssertEqual(result.lifecycle, .empty(epoch: fixture.session.epoch))
    }

    func testSessionBatchBoundRejectsMoreThanTwoHundredMembers() throws {
        let fixture = try Fixture.make()
        let members = (0...CloudStagedTransferLimits.maximumMembersPerBatch).map { index in
            CloudRecordEnvelope(
                resourceKey: .string("staged-\(index)"), workspaceID: fixture.namespace.workspaceID,
                recordType: "NettworkLocation", payload: Data("\(index)".utf8),
                visibility: .staged(transferID: fixture.session.transferID), systemFields: Data(), changeTag: ""
            )
        }
        let sessionEnvelope = CloudRecordEnvelope(
            resourceKey: fixture.session.resourceKey, workspaceID: fixture.namespace.workspaceID,
            recordType: CloudStagedTransferRecordType.session,
            payload: try CloudDeterministicCoding.encode(fixture.session), systemFields: Data([1]), changeTag: "tag"
        )
        let mutation = AtomicCloudMutation(
            operationID: ObjectID(), workspaceZone: fixture.namespace.workspaceZone,
            records: members + [sessionEnvelope],
            preconditions: members.map { .mustNotExist(recordName: $0.recordName) }
                + [.exact(recordName: sessionEnvelope.recordName, systemFields: Data([1]), changeTag: "tag")]
        )
        XCTAssertThrowsError(try AtomicCloudMutationValidator.validate(mutation)) { error in
            XCTAssertEqual(error as? AtomicCloudMutationValidationError, .stagedBatchTooLarge)
        }
    }

    func testGarbageCollectionPolicyAndDeletePageStayBounded() throws {
        XCTAssertEqual(CloudStagedTransferGarbageCollector.maximumDeleteMembersPerPage, 198)
        XCTAssertNoThrow(try CloudStagedTransferGCPolicy(minimumAge: 60, maximumCandidates: 2, maximumPagesPerCandidate: 3))
        XCTAssertThrowsError(try CloudStagedTransferGCPolicy(minimumAge: 0, maximumCandidates: 2, maximumPagesPerCandidate: 3))
        XCTAssertThrowsError(try CloudStagedTransferGCPolicy(minimumAge: 60, maximumCandidates: 101, maximumPagesPerCandidate: 3))
    }

    func testGarbageCollectionStopsWhenActivationReceiptAppearsAfterStagedSentinelRead() async throws {
        let fixture = try Fixture.make()
        let transport = try ActivationRaceGCTransport(fixture: fixture)
        let collector = CloudStagedTransferGarbageCollector(
            policy: try CloudStagedTransferGCPolicy(minimumAge: 60, maximumCandidates: 1, maximumPagesPerCandidate: 1),
            transport: transport,
            authorizer: PermissiveGCAuthorizer()
        )

        do {
            try await collector.collect(in: fixture.namespace.workspaceZone)
            XCTFail("Activation racing staged cleanup must protect the transfer")
        } catch {
            XCTAssertEqual(error as? CloudStagedTransferGCError, .protectedTransfer)
        }

        let appliedMutationCount = await transport.appliedMutationCount()
        let destructiveMutationCount = await transport.destructiveMutationCount()
        XCTAssertEqual(appliedMutationCount, 1, "Only the server-time witness may be written")
        XCTAssertEqual(destructiveMutationCount, 0)
    }
}

private enum Fixture {
    static func make() throws -> (
        namespace: PersistenceNamespace,
        session: CloudStagedTransferSession,
        memberRecord: LocalMirrorRecord,
        sessionRecord: LocalMirrorRecord,
        workspaceEmptyRecord: LocalMirrorRecord,
        workspaceActiveRecord: LocalMirrorRecord
    ) {
        let workspaceID = ObjectID(UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!)
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "owner",
            workspaceID: workspaceID, zoneName: "workspace-zone", zoneOwnerRecordName: "owner", sessionGeneration: 1
        )
        let transferID = ObjectID(UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!)
        let operationID = ObjectID(UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!)
        let member = CloudRecordEnvelope(
            resourceKey: .string("member"), workspaceID: workspaceID, recordType: "NettworkLocation",
            payload: Data("member".utf8), visibility: .staged(transferID: transferID), systemFields: Data([1]), changeTag: "tag"
        )
        let rolling = CloudStagedTransferCommitment.append(
            previous: CloudStagedTransferCommitment.initial(transferID: transferID, operationID: operationID),
            index: 0, memberDigest: CloudStagedTransferCommitment.member(member)
        )
        let session = try CloudStagedTransferSession(
            transferID: transferID, operationID: operationID, epoch: 7,
            expectedMemberCount: 1, expectedRollingDigest: rolling, cursor: 1, rollingDigest: rolling, status: .complete
        )
        let emptyWorkspace = CloudWorkspaceRecord(
            workspaceID: workspaceID, zoneName: namespace.zoneName, zoneOwnerRecordName: namespace.zoneOwnerRecordName, lifecycle: .empty(epoch: 7))
        let activeWorkspace = CloudWorkspaceRecord(
            workspaceID: workspaceID, zoneName: namespace.zoneName, zoneOwnerRecordName: namespace.zoneOwnerRecordName,
            lifecycle: .active(commit: WorkspaceActivationCommit(transferID: transferID, memberCount: 1, rollingDigest: rolling)))
        func record(_ key: ResourceKey, _ type: String, _ payload: Data, visibility: WorkspaceRecordVisibility = .live) -> LocalMirrorRecord {
            LocalMirrorRecord(
                namespace: namespace, resourceKey: key, recordType: type, schemaVersion: 1, payload: payload, systemFields: Data([1]), changeTag: "tag",
                isTombstone: false, visibility: visibility, serverModifiedAt: .distantPast, verifiedAt: .distantPast)
        }
        return (
            namespace, session,
            record(member.resourceKey, member.recordType, member.payload, visibility: member.visibility),
            record(session.resourceKey, CloudStagedTransferRecordType.session, try CloudDeterministicCoding.encode(session)),
            record(.string("workspace-empty"), CloudRecordNaming.workspaceRecordType, try CloudDeterministicCoding.encode(emptyWorkspace)),
            record(.string("workspace-active"), CloudRecordNaming.workspaceRecordType, try CloudDeterministicCoding.encode(activeWorkspace))
        )
    }
}

private actor PermissiveGCAuthorizer: CloudStagedTransferGCAuthorizing {
    func authorizeStagedTransferGC(in _: AuthoritativeWorkspaceZone) async throws {}
}

private actor ActivationRaceGCTransport: CloudStagedTransferGCTransport {
    private let workspaceZone: AuthoritativeWorkspaceZone
    private let sessionSnapshot: CloudExactRecordSnapshot
    private let activationReceipt: CloudExactRecordSnapshot
    private var sentinelSnapshots: [CloudExactRecordSnapshot]
    private var appliedMutations: [CloudStagedTransferGCMutation] = []

    init(
        fixture: (
            namespace: PersistenceNamespace,
            session: CloudStagedTransferSession,
            memberRecord: LocalMirrorRecord,
            sessionRecord: LocalMirrorRecord,
            workspaceEmptyRecord: LocalMirrorRecord,
            workspaceActiveRecord: LocalMirrorRecord
        )
    ) throws {
        workspaceZone = fixture.namespace.workspaceZone
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: fixture.namespace.workspaceID)
        let emptyWorkspace = CloudWorkspaceRecord(
            workspaceID: fixture.namespace.workspaceID,
            zoneName: fixture.namespace.zoneName,
            zoneOwnerRecordName: fixture.namespace.zoneOwnerRecordName,
            lifecycle: .empty(epoch: fixture.session.epoch)
        )
        let originalSentinel = CloudExactRecordSnapshot(
            workspaceZone: fixture.namespace.workspaceZone,
            resourceKey: sentinelKey,
            recordType: CloudRecordNaming.workspaceRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: try CloudDeterministicCoding.encode(emptyWorkspace),
            exactPrecondition: ExactRecordPrecondition(systemFields: Data([1]), changeTag: "empty-v1"),
            serverModifiedAt: .now
        )
        let witnessedSentinel = CloudExactRecordSnapshot(
            workspaceZone: fixture.namespace.workspaceZone,
            resourceKey: sentinelKey,
            recordType: CloudRecordNaming.workspaceRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: try CloudDeterministicCoding.encode(emptyWorkspace),
            exactPrecondition: ExactRecordPrecondition(systemFields: Data([2]), changeTag: "empty-v2"),
            serverModifiedAt: .now
        )
        sentinelSnapshots = [originalSentinel, witnessedSentinel, witnessedSentinel]
        sessionSnapshot = CloudExactRecordSnapshot(
            workspaceZone: fixture.namespace.workspaceZone,
            resourceKey: fixture.session.resourceKey,
            recordType: CloudStagedTransferRecordType.session,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: try CloudDeterministicCoding.encode(fixture.session),
            exactPrecondition: ExactRecordPrecondition(systemFields: Data([3]), changeTag: "session-v1"),
            serverModifiedAt: .distantPast
        )
        activationReceipt = CloudExactRecordSnapshot(
            workspaceZone: fixture.namespace.workspaceZone,
            resourceKey: .operationReceipt(operationID: fixture.session.operationID),
            recordType: CloudRecordNaming.receiptRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: Data("activation-raced".utf8),
            exactPrecondition: ExactRecordPrecondition(systemFields: Data([4]), changeTag: "receipt-v1"),
            serverModifiedAt: .now
        )
    }

    func exactRecord(
        for resourceKey: ResourceKey,
        in _: AuthoritativeWorkspaceZone
    ) async throws -> CloudExactRecordSnapshot? {
        if resourceKey == sessionSnapshot.resourceKey { return sessionSnapshot }
        if resourceKey == activationReceipt.resourceKey { return activationReceipt }
        guard !sentinelSnapshots.isEmpty else { return nil }
        return sentinelSnapshots.removeFirst()
    }

    func stagedTransferSessions(
        olderThan _: Date,
        limit _: Int,
        in _: AuthoritativeWorkspaceZone
    ) async throws -> [CloudExactRecordSnapshot] {
        [sessionSnapshot]
    }

    func stagedTransferMembers(
        transferID _: ObjectID,
        limit _: Int,
        in _: AuthoritativeWorkspaceZone
    ) async throws -> CloudStagedTransferGCMemberPage {
        CloudStagedTransferGCMemberPage(members: [], isComplete: true)
    }

    func applyStagedTransferGC(_ mutation: CloudStagedTransferGCMutation) async throws -> CloudStagedTransferGCResult {
        appliedMutations.append(mutation)
        return .accepted
    }

    func appliedMutationCount() -> Int { appliedMutations.count }
    func destructiveMutationCount() -> Int {
        appliedMutations.filter { !$0.recordNamesToDelete.isEmpty }.count
    }
}
