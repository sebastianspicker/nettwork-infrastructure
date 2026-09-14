import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudSyncV9MaintenanceBehaviorTests: XCTestCase {
    func testDurableTombstonesCannotBeResurrectedByAValidatedCandidate() async throws {
        let namespace = makeNamespace()
        let key = ResourceKey.string("durable-tombstone")
        let candidate = VerifiedCloudRecord(
            envelope: CloudRecordEnvelope(
                resourceKey: key,
                workspaceID: namespace.workspaceID,
                recordType: CloudRecordNaming.workspaceAssetRecordType,
                payload: Data(),
                systemFields: Data(),
                changeTag: "candidate"
            ))
        let snapshot = CloudRemoteMirrorSnapshot(
            existingResourceKeys: [key],
            tombstonedResourceKeys: [key],
            hasCompleteReferenceIndex: true
        )

        do {
            try await TombstoneAwareCloudRemoteReferenceValidator().validate(
                candidate: [candidate], against: snapshot, namespace: namespace
            )
            XCTFail("A durable tombstone must not be resurrected.")
        } catch let error as CloudRemoteReferenceValidationError {
            XCTAssertEqual(
                error,
                .invalidRecords(resourceKeys: [key], reason: "candidate resurrects a durable tombstone")
            )
        }
    }

    func testMaintenanceFactsKeepAStagedTombstoneInItsTransferMembership() throws {
        let namespace = makeNamespace()
        let transferID = ObjectID()
        let envelope = CloudRecordEnvelope(
            resourceKey: .string("staged-tombstone"),
            workspaceID: namespace.workspaceID,
            recordType: CloudRecordNaming.workspaceAssetRecordType,
            payload: Data(),
            visibility: .staged(transferID: transferID),
            systemFields: Data(),
            changeTag: "tombstone",
            isDeleted: true
        )

        let facts = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertEqual(facts.records.count, 1)
        XCTAssertEqual(facts.records[0].references, [])
        XCTAssertEqual(
            facts.records[0].transferMember,
            LocalMirrorTransferMember(
                transferID: transferID,
                resourceKey: envelope.resourceKey,
                digest: CloudStagedTransferCommitment.member(envelope)
            )
        )
    }

    private func makeNamespace() -> PersistenceNamespace {
        let workspaceID = ObjectID()
        return PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "maintenance-owner",
            workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID),
            zoneOwnerRecordName: "maintenance-owner",
            sessionGeneration: 1
        )
    }
}
